import 'package:material_ui/material_ui.dart';

import 'audio_player.dart';
import 'model.dart';
import 'cover_widget.dart';
import 'design.dart';

class PlaybackCard extends StatefulWidget {
  final NativeAudioPlayer player;
  final Track? Function(String?) trackById;
  final void Function(String) onError;
  final VoidCallback onQueue;
  final VoidCallback? onDevices, onExpand;
  final void Function(Track)? onLike;
  final bool expanded;
  const PlaybackCard({
    super.key,
    required this.player,
    required this.trackById,
    required this.onError,
    required this.onQueue,
    this.onLike,
    this.onDevices,
    this.onExpand,
    this.expanded = false,
  });
  @override
  State<PlaybackCard> createState() => _PlaybackCardState();
}

class _PlaybackCardState extends State<PlaybackCard> {
  double? seeking;
  String? seekingTrack;
  Future<void> act(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      widget.onError('Odtwarzanie: $e');
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<AudioSnapshot>(
    stream: widget.player.stream.snapshot,
    initialData: widget.player.state,
    builder: (context, snap) {
      final s = snap.data ?? widget.player.state;
      final track = widget.trackById(s.currentId);
      if (seekingTrack != s.currentId) {
        seeking = null;
        seekingTrack = s.currentId;
      }
      final max = s.duration.inMilliseconds.toDouble();
      final position = (seeking ?? s.position.inMilliseconds.toDouble()).clamp(
        0.0,
        max > 0 ? max : 1.0,
      );
      final reduced = MediaQuery.disableAnimationsOf(context);
      Widget artwork(double size) => RepaintBoundary(
        child: AnimatedSwitcher(
          duration: reduced ? Duration.zero : const Duration(milliseconds: 450),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: .96, end: 1.0).animate(animation),
              child: child,
            ),
          ),
          child: Container(
            key: ValueKey(track?.id),
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .36),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: CoverImage(
                track?.cover,
                width: size,
                height: size,
                cacheWidth: (size * 2).ceil(),
              ),
            ),
          ),
        ),
      );
      Widget description = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              PlayingBars(playing: s.playing, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.playing ? 'Teraz odtwarzane' : 'Gotowe do słuchania',
                  maxLines: 2,
                  style: const TextStyle(color: secondaryText, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            track?.title ?? 'Twoja muzyka czeka',
            maxLines: widget.expanded ? 4 : 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: widget.expanded ? 30 : 24,
              fontWeight: FontWeight.w800,
              height: 1.1,
              letterSpacing: -.7,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            track?.displayArtist ?? 'Wybierz album z biblioteki',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: secondaryText, fontSize: 15),
          ),
          if (track != null) ...[
            const SizedBox(height: 12),
            Text(
              [
                track.format.toUpperCase(),
                if (track.sampleRate > 0) '${track.sampleRate / 1000} kHz',
                if (track.bitDepth > 0) '${track.bitDepth} bit',
              ].join(' · '),
              style: const TextStyle(
                color: secondaryText,
                fontSize: 10,
                letterSpacing: .5,
              ),
            ),
            if (widget.onLike != null)
              IconButton(
                tooltip: track.liked
                    ? 'Usuń z polubionych'
                    : 'Dodaj do polubionych',
                onPressed: () => widget.onLike!(track),
                icon: AnimatedSwitcher(
                  duration: reduced
                      ? Duration.zero
                      : const Duration(milliseconds: 240),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutBack,
                    ),
                    child: child,
                  ),
                  child: Icon(
                    track.liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    key: ValueKey(track.liked),
                    color: track.liked ? accent : secondaryText,
                  ),
                ),
              ),
          ],
        ],
      );
      return LayoutBuilder(
        builder: (context, bounds) {
          final narrow = bounds.maxWidth < 460;
          final vertical = widget.expanded || bounds.maxWidth < 260;
          final artSize = vertical
              ? (bounds.maxWidth - 40).clamp(0.0, 390.0)
              : (bounds.maxWidth * (narrow ? .44 : .36)).clamp(90.0, 260.0);
          return AmbientSurface(
            active: s.playing,
            child: Padding(
              padding: EdgeInsets.all(narrow ? 18 : 26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (vertical) ...[
                    Center(child: artwork(artSize)),
                    const SizedBox(height: 26),
                    description,
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: widget.onExpand,
                          borderRadius: BorderRadius.circular(20),
                          child: artwork(artSize),
                        ),
                        SizedBox(width: narrow ? 16 : 28),
                        Expanded(child: description),
                      ],
                    ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: 'Losowa kolejność',
                        color: s.shuffled ? accent : secondaryText,
                        onPressed: track == null
                            ? null
                            : () =>
                                  act(() => widget.player.shuffle(!s.shuffled)),
                        icon: const Icon(Icons.shuffle_rounded, size: 23),
                      ),
                      IconButton(
                        tooltip: 'Poprzedni utwór',
                        onPressed: track == null
                            ? null
                            : () => act(widget.player.previous),
                        icon: const Icon(Icons.skip_previous_rounded, size: 32),
                      ),
                      PlayButton(
                        playing: s.playing,
                        size: bounds.maxWidth < 300
                            ? 52
                            : narrow
                            ? 60
                            : 68,
                        onPressed: track == null
                            ? null
                            : () => act(widget.player.playOrPause),
                      ),
                      IconButton(
                        tooltip: 'Następny utwór',
                        onPressed: track == null
                            ? null
                            : () => act(widget.player.next),
                        icon: const Icon(Icons.skip_next_rounded, size: 32),
                      ),
                      IconButton(
                        tooltip: 'Powtarzaj kolejkę',
                        color: s.repeat ? accent : secondaryText,
                        onPressed: track == null
                            ? null
                            : () => act(() => widget.player.repeat(!s.repeat)),
                        icon: const Icon(Icons.repeat_rounded, size: 23),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Semantics(
                    label: 'Pozycja odtwarzania',
                    child: Slider(
                      value: position,
                      max: max > 0 ? max : 1.0,
                      onChanged: max <= 0
                          ? null
                          : (v) => setState(() => seeking = v),
                      onChangeEnd: max <= 0
                          ? null
                          : (v) async {
                              await act(
                                () => widget.player.seek(
                                  Duration(milliseconds: v.round()),
                                ),
                              );
                              if (mounted) setState(() => seeking = null);
                            },
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        durationLabel(position.round()),
                        style: const TextStyle(
                          color: secondaryText,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        durationLabel(max.round()),
                        style: const TextStyle(
                          color: secondaryText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  if (widget.expanded) ...[
                    const SizedBox(height: 20),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 10,
                      children: [
                        if (widget.onDevices != null)
                          TextButton.icon(
                            onPressed: widget.onDevices,
                            icon: const Icon(
                              Icons.speaker_group_outlined,
                              size: 20,
                            ),
                            label: const Text('Odtwarzaj na'),
                          ),
                        TextButton.icon(
                          onPressed: widget.onQueue,
                          icon: const Icon(Icons.queue_music_rounded, size: 20),
                          label: const Text('Kolejka odtwarzania'),
                        ),
                      ],
                    ),
                  ],
                  if (s.buffering) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                    const Text(
                      'Buforowanie…',
                      style: TextStyle(color: secondaryText, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
