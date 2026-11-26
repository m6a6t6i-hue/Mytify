import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'design.dart';

/// Marks a cover URI as a station logo: small source images that must not be
/// stretched over a whole cover. The fragment never reaches the server.
const logoMark = '#station-logo';

String asLogo(String uri) => '$uri$logoMark';
bool isLogo(String? uri) => uri != null && uri.endsWith(logoMark);

final _backgrounds = <String, Color?>{};

/// Station logo drawn at most at twice its own pixel size (so it stays sharp), centred
/// on a field in the logo's own background colour, read from its edge pixels.
class LogoArt extends StatefulWidget {
  final String uri;
  final double? width, height;
  final Widget fallback;

  /// How much of the field the logo may take at most.
  final double fill;
  const LogoArt(this.uri, {super.key, this.width, this.height, required this.fallback, this.fill = .62});
  @override
  State<LogoArt> createState() => _LogoArtState();
}

class _LogoArtState extends State<LogoArt> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _image;
  Color? _background;
  bool _failed = false;

  String get _url => widget.uri.endsWith(logoMark) ? widget.uri.substring(0, widget.uri.length - logoMark.length) : widget.uri;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(LogoArt old) {
    super.didUpdateWidget(old);
    if (old.uri != widget.uri) _resolve();
  }

  void _resolve() {
    final next = NetworkImage(_url).resolve(createLocalImageConfiguration(context));
    if (_stream?.key == next.key) return;
    _stop();
    _failed = false;
    _background = _backgrounds[_url];
    _stream = next;
    _listener = ImageStreamListener(
      (info, _) {
        final url = _url;
        if (!mounted) {
          info.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = info.image.clone();
        });
        info.dispose();
        if (!_backgrounds.containsKey(url)) {
          edgeColor(_image!).then((c) {
            if (_backgrounds.length > 300) _backgrounds.clear();
            _backgrounds[url] = c;
            if (mounted && url == _url) setState(() => _background = c);
          });
        }
      },
      onError: (_, _) {
        if (mounted) setState(() => _failed = true);
      },
    );
    next.addListener(_listener!);
  }

  void _stop() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stop();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (_failed) return widget.fallback;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final w = widget.width ?? (box.maxWidth.isFinite ? box.maxWidth : 120.0);
        final h = widget.height ?? (box.maxHeight.isFinite ? box.maxHeight : w);
        Widget? logo;
        if (image != null) {
          // Never more than twice the logo's own resolution: beyond that it only gets blurrier.
          final natural = math.max(image.width, image.height) / dpr * 2;
          final side = math.min(math.min(w, h) * widget.fill, natural);
          final aspect = image.width / math.max(1, image.height);
          logo = RawImage(
            image: image,
            width: aspect >= 1 ? side : side * aspect,
            height: aspect >= 1 ? side / aspect : side,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          );
        }
        return Container(
          width: w,
          height: h,
          color: _background ?? elevated,
          alignment: Alignment.center,
          child: logo,
        );
      },
    );
  }
}

/// The logo's background: the most common colour along its edges. A transparent edge
/// gets a light field for dark logos and a dark one for light logos.
Future<Color?> edgeColor(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return null;
  final w = image.width, h = image.height;
  final buckets = <int, List<int>>{};
  var transparent = 0, total = 0;
  void sample(int x, int y) {
    final i = (y * w + x) * 4;
    final r = data.getUint8(i), g = data.getUint8(i + 1), b = data.getUint8(i + 2), a = data.getUint8(i + 3);
    total++;
    if (a < 200) {
      transparent++;
      return;
    }
    final key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
    final sum = buckets.putIfAbsent(key, () => [0, 0, 0, 0]);
    sum[0] += r;
    sum[1] += g;
    sum[2] += b;
    sum[3]++;
  }

  final step = math.max(1, math.max(w, h) ~/ 64);
  for (var x = 0; x < w; x += step) {
    sample(x, 0);
    sample(x, h - 1);
  }
  for (var y = 0; y < h; y += step) {
    sample(0, y);
    sample(w - 1, y);
  }
  if (total == 0) return null;
  if (transparent > total / 2) {
    // Transparent logo: how bright is what is drawn?
    var lum = 0.0, n = 0;
    final stride = math.max(1, (w * h) ~/ 4096);
    for (var p = 0; p < w * h; p += stride) {
      final i = p * 4;
      if (data.getUint8(i + 3) < 128) continue;
      lum += .2126 * data.getUint8(i) + .7152 * data.getUint8(i + 1) + .0722 * data.getUint8(i + 2);
      n++;
    }
    if (n == 0) return null;
    return lum / n < 110 ? const Color(0xfff2f2f2) : const Color(0xff1b1d20);
  }
  final best = buckets.values.reduce((a, b) => a[3] >= b[3] ? a : b);
  return Color.fromARGB(255, best[0] ~/ best[3], best[1] ~/ best[3], best[2] ~/ best[3]);
}
