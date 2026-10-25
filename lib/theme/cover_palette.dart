import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_color_utilities/quantize/quantizer_celebi.dart';
import 'package:material_color_utilities/score/score.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/widgets/cached_cover_image.dart';

Future<List<List<int>>> _quantizePaletteInIsolate(Uint8List bytes) async {
  final result = await QuantizerCelebi().quantize(
    bytes.buffer.asUint32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4),
    128,
  );
  return [
    for (final entry in result.colorToCount.entries) [entry.key, entry.value],
  ];
}

/// Score remains pinned to Flutter's Material implementation. Quantization
/// runs on the native worker; the byte-order conversion matches ColorScheme.
int paletteSeedFromColorCounts(List<List<int>> colors) {
  final populations = <int, int>{};
  for (final pair in colors) {
    final abgr = pair[0];
    final argb =
        (abgr & 0xff00ff00) | ((abgr & 255) << 16) | ((abgr >> 16) & 255);
    populations[argb] = pair[1];
  }
  return Score.score(populations, desired: 1).first;
}

/// Colour scheme derived from cover art, used to theme detail-screen headers.
///
/// The generated scheme follows app brightness and supplies contrasting
/// on-colours for the artwork-derived surface.
class CoverPalette {
  const CoverPalette._();

  /// Quantizing an image is not cheap, so results are memoized per
  /// URL+brightness. Bounded because a long library-browsing session would
  /// otherwise keep every visited album's scheme alive.
  static final Map<String, ColorScheme> _cache = <String, ColorScheme>{};
  static final Map<String, Color> _sourceColors = {};
  static final Map<String, Future<ColorScheme?>> _pending = {};
  static final Map<String, String> _sourceKeys = {};
  static final List<String> _cacheOrder = <String>[];
  static const int _maxEntries = 32;

  static bool _isNetworkSource(String source) =>
      source.startsWith('http://') || source.startsWith('https://');

  /// Includes the local file version so replacing artwork at the same path
  /// cannot reuse a palette derived from the previous image.
  static Future<String> cacheKeyFor(
    String source,
    Brightness brightness,
  ) async {
    var versionedSource = source;
    if (!_isNetworkSource(source)) {
      try {
        final stat = await File(source).stat();
        if (stat.type != FileSystemEntityType.notFound) {
          versionedSource =
              '$source|${stat.modified.microsecondsSinceEpoch}|${stat.size}';
        }
      } catch (_) {
        // Resolution below will return null for inaccessible local files.
      }
    }
    return '$versionedSource|${brightness.name}';
  }

  /// Cached scheme for [source], or null when it has not been resolved yet.
  static ColorScheme? peek(String source, Brightness brightness) =>
      _cache[_sourceKeys['$source|${brightness.name}']];

  /// Average cover colour before Material's accent selection or tonal mapping.
  /// Near-monochrome covers stay neutral instead of acquiring a seed hue.
  static Color? sourceColor(String source, Brightness brightness) =>
      _sourceColors[_sourceKeys['$source|${brightness.name}']];

  /// Resolves the scheme for [source] (a network URL or a local file path).
  /// Returns null when the image cannot be decoded.
  static Future<ColorScheme?> resolve(
    String source,
    Brightness brightness, {
    String? cacheKey,
  }) {
    final sourceKey = '$source|${brightness.name}';
    return _pending.putIfAbsent(
      sourceKey,
      () =>
          (() async {
            final key = cacheKey ?? await cacheKeyFor(source, brightness);
            final previous = _sourceKeys.remove(sourceKey);
            // FileImage keys contain the path, not its modification time. A new
            // palette key also needs a fresh decode after an in-place cover edit.
            if ((!_cache.containsKey(key) ||
                    (previous != null && previous != key)) &&
                !_isNetworkSource(source)) {
              if (previous != null && previous != key) {
                await _evictDecodedImage(FileImage(File(source)));
              }
              await _evictDecodedImage(
                ResizeImage(
                  FileImage(File(source)),
                  width: 112,
                  height: 112,
                  policy: ResizeImagePolicy.fit,
                ),
              );
            }
            _sourceKeys[sourceKey] = key;
            while (_sourceKeys.length > _maxEntries) {
              _sourceKeys.remove(_sourceKeys.keys.first);
            }
            return _cache[key] ?? await _resolve(source, brightness, key);
          })().whenComplete(() {
            _pending.remove(sourceKey);
          }),
    );
  }

  static Future<void> _evictDecodedImage(ImageProvider provider) async {
    final key = await provider.obtainKey(ImageConfiguration.empty);
    // A first palette request can overlap the header's initial precache. Do
    // not cancel that pending decode while removing an older retained bitmap.
    if (!PaintingBinding.instance.imageCache.statusForKey(key).pending) {
      await provider.evict();
    }
  }

  static Future<ColorScheme?> _resolve(
    String source,
    Brightness brightness,
    String key,
  ) async {
    final ImageProvider provider;
    if (_isNetworkSource(source)) {
      provider = cachedCoverImageProvider(source);
    } else {
      final file = File(source);
      if (!await file.exists()) return null;
      provider = FileImage(file);
    }

    try {
      // Both samplers share this bounded decode through Flutter's image cache.
      final sample = ResizeImage(
        provider,
        width: 112,
        height: 112,
        policy: ResizeImagePolicy.fit,
      );
      final scheme = await _schemeFromSample(sample, brightness);
      final sourceColor = await _sampleSourceColor(sample);
      if (sourceColor != null) _sourceColors[key] = sourceColor;
      _cache[key] = scheme;
      _cacheOrder.add(key);
      while (_cacheOrder.length > _maxEntries) {
        final oldest = _cacheOrder.removeAt(0);
        _cache.remove(oldest);
        _sourceColors.remove(oldest);
      }
      return scheme;
    } catch (_) {
      // Unreachable URL, unsupported format, decode failure: callers fall back
      // to the app scheme.
      return null;
    }
  }

  static Future<ColorScheme> _schemeFromSample(
    ImageProvider provider,
    Brightness brightness,
  ) async {
    final result = Completer<Uint8List>();
    final stream = provider.resolve(
      const ImageConfiguration(size: Size(112, 112)),
    );
    late ImageStreamListener listener;
    late Timer loadFailureTimeout;
    listener = ImageStreamListener(
      (info, _) async {
        loadFailureTimeout.cancel();
        stream.removeListener(listener);
        ui.Picture? picture;
        ui.Image? image;
        try {
          final source = info.image;
          // Mirror Flutter's image-to-palette canvas/readback. Decoding,
          // filtering and premultiplied alpha remain with Flutter's renderer.
          final recorder = ui.PictureRecorder();
          paintImage(
            canvas: Canvas(recorder),
            rect: Rect.fromLTWH(
              0,
              0,
              source.width.toDouble(),
              source.height.toDouble(),
            ),
            image: source,
            filterQuality: FilterQuality.none,
          );
          picture = recorder.endRecording();
          image = await picture.toImage(source.width, source.height);
          final data = await image.toByteData();
          if (data == null) throw StateError('Palette readback failed');
          result.complete(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        } catch (error, stack) {
          result.completeError(error, stack);
        } finally {
          image?.dispose();
          picture?.dispose();
          info.dispose();
        }
      },
      onError: (Object error, StackTrace? stack) {
        loadFailureTimeout.cancel();
        stream.removeListener(listener);
        result.completeError(error, stack);
      },
    );
    loadFailureTimeout = Timer(const Duration(seconds: 5), () {
      stream.removeListener(listener);
      result.completeError(TimeoutException('Palette image loading timed out'));
    });
    stream.addListener(listener);
    final bytes = await result.future;
    late final List<List<int>> colors;
    try {
      final response = await PlatformBridge.runNativeDataJob({
        'operation': 'palette',
      }, bytes: bytes);
      colors = [
        for (final pair in response['colors'] as List)
          [for (final value in pair as List) (value as num).toInt()],
      ];
    } on MissingPluginException {
      // Desktop tests and unsupported hosts retain exact Material output,
      // with the same expensive quantizer moved off the UI isolate.
      colors = await compute(_quantizePaletteInIsolate, bytes);
    }
    final seed = await compute(paletteSeedFromColorCounts, colors);
    return ColorScheme.fromSeed(seedColor: Color(seed), brightness: brightness);
  }

  static Future<Color?> _sampleSourceColor(ImageProvider provider) {
    final result = Completer<Color?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) async {
        stream.removeListener(listener);
        try {
          final data = await info.image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          if (data == null) {
            result.complete(null);
            return;
          }
          var red = 0.0;
          var green = 0.0;
          var blue = 0.0;
          var weight = 0.0;
          for (var index = 0; index < data.lengthInBytes; index += 4) {
            final alpha = data.getUint8(index + 3) / 255;
            red += data.getUint8(index) * alpha;
            green += data.getUint8(index + 1) * alpha;
            blue += data.getUint8(index + 2) * alpha;
            weight += alpha;
          }
          if (weight == 0) {
            result.complete(null);
            return;
          }
          red /= weight;
          green /= weight;
          blue /= weight;
          // A very dark navy pixel can have high HSL saturation despite being
          // visually black. Compare channel differences before using its hue.
          final spread =
              math.max(red, math.max(green, blue)) -
              math.min(red, math.min(green, blue));
          if (spread < 16) {
            final gray = (red * 0.2126 + green * 0.7152 + blue * 0.0722)
                .round();
            result.complete(Color.fromARGB(255, gray, gray, gray));
          } else {
            result.complete(
              Color.fromARGB(255, red.round(), green.round(), blue.round()),
            );
          }
        } catch (_) {
          result.complete(null);
        } finally {
          info.dispose();
        }
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
        result.complete(null);
      },
    );
    stream.addListener(listener);
    return result.future;
  }
}

/// Exposes the header's effective [ColorScheme] to descendants.
///
/// Header sub-widgets (meta rows, circle buttons, play actions) live in the
/// screens' own build methods, so they cannot be handed the palette directly;
/// they read it from here and fall back to the app scheme when absent.
class HeaderPalette extends InheritedWidget {
  const HeaderPalette({super.key, required this.scheme, required super.child});

  final ColorScheme scheme;

  static ColorScheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HeaderPalette>()?.scheme ??
      Theme.of(context).colorScheme;

  @override
  bool updateShouldNotify(HeaderPalette oldWidget) =>
      scheme != oldWidget.scheme;
}

/// Resolves [imageSource] into a [ColorScheme] and rebuilds when it arrives.
class CoverPaletteBuilder extends StatefulWidget {
  const CoverPaletteBuilder({
    super.key,
    required this.imageSource,
    required this.builder,
  });

  /// Cover URL or local path. Null disables palette extraction.
  final String? imageSource;

  final Widget Function(BuildContext context, ColorScheme scheme) builder;

  @override
  State<CoverPaletteBuilder> createState() => _CoverPaletteBuilderState();
}

class _CoverPaletteBuilderState extends State<CoverPaletteBuilder> {
  ColorScheme? _scheme;
  String? _resolvedSource;
  Brightness? _resolvedBrightness;
  int _resolveGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeResolve();
  }

  @override
  void didUpdateWidget(CoverPaletteBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-check local file identity even when its path did not change. Metadata
    // editing can replace cover bytes in place.
    _maybeResolve();
  }

  void _maybeResolve() {
    final source = widget.imageSource;
    final brightness = Theme.of(context).brightness;
    if (source == null || source.isEmpty) {
      _resolveGeneration++;
      _resolvedSource = null;
      _resolvedBrightness = null;
      _scheme = null;
      return;
    }
    final requestGeneration = ++_resolveGeneration;
    if (_resolvedSource != source || _resolvedBrightness != brightness) {
      _resolvedSource = source;
      _resolvedBrightness = brightness;
      _scheme = CoverPalette.peek(source, brightness);
    }

    CoverPalette.resolve(source, brightness).then((scheme) {
      if (!mounted) return;
      if (_resolveGeneration != requestGeneration) {
        return;
      }
      if (_scheme != scheme) setState(() => _scheme = scheme);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = _scheme ?? Theme.of(context).colorScheme;
    return HeaderPalette(
      scheme: scheme,
      child: widget.builder(context, scheme),
    );
  }
}
