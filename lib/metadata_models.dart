import 'l10n.dart';
class MetadataEdit {
  final String id;
  final Map<String, dynamic> patch;
  const MetadataEdit(this.id, this.patch);
  Map<String, dynamic> toJson() => {'id': id, 'patch': patch};
}

class CoverChoice {
  final String hash, uri;
  const CoverChoice(this.hash, this.uri);
  static CoverChoice? fromJson(Map<String, dynamic> j) => j['hash'] == null
      ? null
      : CoverChoice(j['hash'] as String, j['uri'] as String);
}

class ReleaseCandidate {
  final String id,
      title,
      artist,
      date,
      country,
      format,
      label,
      barcode,
      disambiguation;
  final int trackCount, score;
  const ReleaseCandidate({
    required this.id,
    required this.title,
    required this.artist,
    required this.date,
    required this.country,
    required this.format,
    required this.label,
    required this.barcode,
    required this.disambiguation,
    required this.trackCount,
    required this.score,
  });
  factory ReleaseCandidate.fromJson(Map<String, dynamic> j) => ReleaseCandidate(
    id: j['id'] as String,
    title: j['title'] as String,
    artist: j['artist'] as String,
    date: j['date'] as String,
    country: j['country'] as String,
    format: j['format'] as String,
    label: j['label'] as String,
    barcode: j['barcode'] as String,
    disambiguation: j['disambiguation'] as String,
    trackCount: (j['trackCount'] as num).toInt(),
    score: (j['score'] as num).toInt(),
  );
  String get description => [
    artist,
    date,
    country,
    format,
    tr('{0} utworów', [trackCount]),
    if (label.isNotEmpty) label,
    if (disambiguation.isNotEmpty) disambiguation,
  ].where((s) => s.isNotEmpty).join(' · ');
}

class ReleaseSong {
  final String title, artist;
  final int discNumber, trackNumber, durationMs;

  /// Printed position, e.g. "A1" on vinyl (may be empty).
  final String number;
  const ReleaseSong({
    required this.title,
    required this.artist,
    required this.discNumber,
    required this.trackNumber,
    required this.durationMs,
    this.number = '',
  });
  factory ReleaseSong.fromJson(Map<String, dynamic> j) => ReleaseSong(
    title: j['title'] as String,
    artist: j['artist'] as String,
    discNumber: (j['discNumber'] as num).toInt(),
    trackNumber: (j['trackNumber'] as num).toInt(),
    durationMs: (j['durationMs'] as num).toInt(),
    number: j['number'] as String? ?? '',
  );
  String get position => '$discNumber.$trackNumber';
}

class ReleaseInfo {
  final ReleaseCandidate release;
  final List<ReleaseSong> tracks;
  const ReleaseInfo(this.release, this.tracks);
  factory ReleaseInfo.fromJson(Map<String, dynamic> j) => ReleaseInfo(
    ReleaseCandidate.fromJson(j['release'] as Map<String, dynamic>),
    (j['tracks'] as List)
        .map((v) => ReleaseSong.fromJson(v as Map<String, dynamic>))
        .toList(),
  );
}
