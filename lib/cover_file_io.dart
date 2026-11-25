import 'dart:io';

import 'package:material_ui/material_ui.dart';

Widget? localCover(
  String uri,
  double? width,
  double? height,
  int? cacheWidth,
) => uri.startsWith('file:')
    ? Image.file(
        File.fromUri(Uri.parse(uri)),
        width: width,
        height: height,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        errorBuilder: (_, _, _) => const Icon(Icons.album_outlined),
      )
    : null;

ImageProvider? localProvider(String uri) =>
    uri.startsWith('file:') ? FileImage(File.fromUri(Uri.parse(uri))) : null;
