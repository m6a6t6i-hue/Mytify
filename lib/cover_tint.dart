import 'dart:async';
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

  static Future<Color?> _compute(String uri) async {
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
    try {
      final image = await completer.future.timeout(const Duration(seconds: 6));
      if (image == null) return null;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      double r = 0, g = 0, b = 0, weight = 0;
      for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
        final cr = data.getUint8(i) / 255,
            cg = data.getUint8(i + 1) / 255,
            cb = data.getUint8(i + 2) / 255;
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
