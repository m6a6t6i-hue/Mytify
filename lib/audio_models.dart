class AudioDevice {
  final String id, name;
  const AudioDevice(this.id, this.name);
  factory AudioDevice.fromJson(Map<String, dynamic> j) =>
      AudioDevice(j['id'] as String, j['name'] as String);
}

class AudioSnapshot {
  final bool available,
      playing,
      completed,
      buffering,
      repeat,
      shuffled,
      pairingRequired,
      volumeAvailable;
  final List<String> queueIds;
  final String? currentId, error;
  final int index, errorSerial, revision, underrunFrames, renderedFrames;
  final double volume;
  final Duration position, duration;
  final Map<String, dynamic>? source, output;
  final String selectedDevice;
  const AudioSnapshot({
    this.volumeAvailable = true,
    this.pairingRequired = false,
    this.available = true,
    this.playing = false,
    this.completed = false,
    this.buffering = false,
    this.repeat = false,
    this.shuffled = false,
    this.queueIds = const [],
    this.currentId,
    this.error,
    this.index = 0,
    this.errorSerial = 0,
    this.revision = 0,
    this.underrunFrames = 0,
    this.renderedFrames = 0,
    this.volume = 80,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.source,
    this.output,
    this.selectedDevice = 'auto',
  });
  factory AudioSnapshot.fromJson(Map<String, dynamic> j) => AudioSnapshot(
    volumeAvailable: j['volumeAvailable'] != false,
    pairingRequired: j['pairingRequired'] == true,
    available: j['available'] == true,
    playing: j['playing'] == true,
    completed: j['completed'] == true,
    buffering: j['buffering'] == true,
    repeat: j['repeat'] == true,
    shuffled: j['shuffled'] == true,
    queueIds: (j['queueIds'] as List).cast<String>(),
    currentId: j['currentId'] as String?,
    error: j['error'] as String?,
    index: (j['index'] as num).toInt(),
    errorSerial: (j['errorSerial'] as num).toInt(),
    revision: (j['revision'] as num).toInt(),
    underrunFrames: (j['underrunFrames'] as num).toInt(),
    renderedFrames: (j['renderedFrames'] as num).toInt(),
    volume: (j['volume'] as num).toDouble(),
    position: Duration(milliseconds: (j['positionMs'] as num).toInt()),
    duration: Duration(milliseconds: (j['durationMs'] as num).toInt()),
    source: j['source'] as Map<String, dynamic>?,
    output: j['output'] as Map<String, dynamic>?,
    selectedDevice: j['selectedDevice'] as String,
  );
}
