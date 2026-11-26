import 'dart:convert';
import 'dart:typed_data';

import 'design.dart';
import 'logo_art.dart';

import 'package:material_ui/material_ui.dart';

import 'cover_file_stub.dart' if (dart.library.io) 'cover_file_io.dart';

final _dataCache = <String, Uint8List>{};

/// Same bytes object for the same data URI, so the image cache key stays stable
/// across rebuilds (players rebuild several times per second).
Uint8List dataBytes(String uri) {
  final hit = _dataCache[uri];
  if (hit != null) return hit;
  if (_dataCache.length > 64) _dataCache.remove(_dataCache.keys.first);
  return _dataCache[uri] = base64Decode(uri.split(',').last);
}

class CoverImage extends StatelessWidget {
  final String? uri;
  final double? width, height;
  final int? cacheWidth;
  const CoverImage(
    this.uri, {
    super.key,
    this.width,
    this.height,
    this.cacheWidth,
  });
  @override
  Widget build(BuildContext context) {
    final value = uri;
    if (isLogo(value)) {
      return LogoArt(value!, width: width, height: height, fallback: CoverImage(null, width: width, height: height));
    }
    if (value != null) {
      final local = localCover(value, width, height, cacheWidth);
      if (local != null) {
        return local;
      }
      if (value.startsWith('data:')) {
        try {
          return Image.memory(
            dataBytes(value),
            width: width,
            height: height,
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            errorBuilder: (_, _, _) => const Icon(Icons.album_outlined),
          );
        } catch (_) {
          /* fallback */
        }
      }
      if (value.startsWith('http')) {
        return Image.network(
          value,
          width: width,
          height: height,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          errorBuilder: (_, _, _) => const Icon(Icons.album_outlined),
        );
      }
    }
    return Container(
      width: width,
      height: height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff1d4c31), Color(0xff101c15)],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.album_outlined,
        size: width == null ? 36 : width! * 0.43,
        color: accent.withValues(alpha: .55),
      ),
    );
  }
}
