import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'cover_file_stub.dart' if (dart.library.io) 'cover_file_io.dart';
import 'cover_widget.dart';
import 'design.dart';

/// Dominant, saturated cover colour for ambient backgrounds. Cached per artwork.
class CoverTint {
  static final _cache = <String, Future<Color?>>{};

  static Future<Color?> of(String? uri) {
    if (uri == null) return Future.value(null);
    if (_cache.length > 200) _cache.clear();
    return _cache.putIfAbsent(uri, () => _compute(uri));
  }

  static ImageProvider? provider(String uri) {
    if (uri.startsWith('data:')) {
      try {
        return MemoryImage(dataBytes(uri));
      } catch (_) {
        return null;
      }
    }
    if (uri.startsWith('http')) return NetworkImage(uri);
    return localProvider(uri);
  }

  static final _palettes = <String, Future<List<Color>?>>{};

  /// Three vivid colours of the artwork, most present first, for the visualizer.
  /// Grey or black covers give null (the visualizer keeps its own palette).
  static Future<List<Color>?> palette(String? uri) {
    if (uri == null) return Future.value(null);
    if (_palettes.length > 100) _palettes.clear();
    return _palettes.putIfAbsent(uri, () async {
      try {
        final data = await _pixels(uri);
        return data == null ? null : paletteOf(data);
      } catch (_) {
        return null;
      }
    });
  }

  /// Hue histogram of RGBA pixels: picks up to three separated hues weighted by how
  /// colourful and how common they are. Pure function, tested directly.
  static List<Color>? paletteOf(List<int> rgba) {
    const bins = 24;
    final weight = List.filled(bins, 0.0);
    final sum = List.generate(bins, (_) => [0.0, 0.0, 0.0]);
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final c = Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
      final hsv = HSVColor.fromColor(c);
      if (hsv.saturation < .22 || hsv.value < .18) continue;
      final w = hsv.saturation * hsv.value;
      final b = (hsv.hue / 360 * bins).floor() % bins;
      weight[b] += w;
      sum[b][0] += c.r * w;
      sum[b][1] += c.g * w;
      sum[b][2] += c.b * w;
    }
    final total = weight.fold(0.0, (a, b) => a + b);
    // Under ~4% colourful pixels the cover is effectively grey.
    if (total < rgba.length / 4 * .04) return null;
    final order = List.generate(bins, (i) => i)..sort((a, b) => weight[b].compareTo(weight[a]));
    final picked = <int>[];
    for (final b in order) {
      if (weight[b] < total * .03) break;
      if (picked.every((p) {
        final d = (p - b).abs();
        return math.min(d, bins - d) >= 3;
      })) {
        picked.add(b);
      }
      if (picked.length == 3) break;
    }
    Color vivid(Color c) {
      final hsv = HSVColor.fromColor(c);
      return hsv.withSaturation(hsv.saturation.clamp(.6, 1)).withValue(hsv.value.clamp(.75, .95)).toColor();
    }

    final colors = [
      for (final b in picked) vivid(Color.from(alpha: 1, red: sum[b][0] / weight[b], green: sum[b][1] / weight[b], blue: sum[b][2] / weight[b])),
    ];
    // One or two hues: neighbours on the colour wheel complete the set.
    while (colors.length < 3) {
      final h = HSVColor.fromColor(colors.first);
      colors.add(h.withHue((h.hue + (colors.length == 1 ? 40 : -40)) % 360).toColor());
    }
    return colors;
  }

  static Future<List<int>?> _pixels(String uri) async {
    final base = provider(uri);
    if (base == null) return null;
    final completer = Completer<ui.Image?>();
    final stream = ResizeImage(
      base,
      width: 24,
      height: 24,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future.timeout(const Duration(seconds: 6));
    if (image == null) return null;
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))?.buffer.asUint8List();
  }

  static Future<Color?> _compute(String uri) async {
    try {
      final data = await _pixels(uri);
      if (data == null) return null;
      double r = 0, g = 0, b = 0, weight = 0;
      for (var i = 0; i + 3 < data.length; i += 4) {
        final cr = data[i] / 255,
            cg = data[i + 1] / 255,
            cb = data[i + 2] / 255;
        final hi = [cr, cg, cb].reduce((x, y) => x > y ? x : y);
        final lo = [cr, cg, cb].reduce((x, y) => x < y ? x : y);
        final w = .08 + (hi - lo) * 2 + (hi > .12 && hi < .95 ? .3 : 0);
        r += cr * w;
        g += cg * w;
        b += cb * w;
        weight += w;
      }
      if (weight == 0) return null;
      final c = Color.from(
        alpha: 1,
        red: r / weight,
        green: g / weight,
        blue: b / weight,
      );
      final hsl = HSLColor.fromColor(c);
      return hsl
          .withLightness(hsl.lightness.clamp(.22, .42))
          .withSaturation((hsl.saturation * 1.1).clamp(0, .75))
          .toColor();
    } catch (_) {
      return null;
    }
  }
}

/// Background that crossfades to the colour of the current artwork.
class AmbientBackdrop extends StatelessWidget {
  final String? cover;
  final Widget child;
  final double strength;
  const AmbientBackdrop({
    super.key,
    required this.cover,
    required this.child,
    this.strength = 1,
  });
  @override
  Widget build(BuildContext context) => FutureBuilder<Color?>(
    future: CoverTint.of(cover),
    builder: (context, snap) {
      final tint = snap.data ?? elevated;
      return TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: tint),
        duration: motion(context, Dur.ambient),
        curve: Curves.easeOutCubic,
        builder: (context, color, _) => DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(background, color ?? tint, .78 * strength)!,
                Color.lerp(background, color ?? tint, .28 * strength)!,
                background,
              ],
              stops: const [0, .55, 1],
            ),
          ),
          child: child,
        ),
      );
    },
  );
}
