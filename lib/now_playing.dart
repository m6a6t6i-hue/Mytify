import 'package:material_ui/material_ui.dart';

import 'audio_player.dart';
import 'model.dart';
import 'playback_card.dart';
import 'design.dart';

class NowPlaying extends StatelessWidget {
  final NativeAudioPlayer player;
  final Track? Function(String?) trackById;
  final VoidCallback onQueue;
  final VoidCallback? onDevices;
  final void Function(Track)? onLike;
  final void Function(String) onError;
  const NowPlaying({
    super.key,
    required this.player,
    required this.trackById,
    required this.onQueue,
    required this.onError,
    this.onDevices,
    this.onLike,
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .9,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'TWOJA MUZYKA. TWÓJ MOMENT.',
                      style: TextStyle(
                        color: secondaryText,
                        fontSize: 10,
                        letterSpacing: 1.8,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zamknij odtwarzacz',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              PlaybackCard(
                player: player,
                trackById: trackById,
                onError: onError,
                onQueue: onQueue,
                onDevices: onDevices,
                onLike: onLike,
                expanded: true,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
