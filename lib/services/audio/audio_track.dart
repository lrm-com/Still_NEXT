import 'dart:typed_data';

/// Minimal track metadata required by the audio layer.
class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.filePath,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.duration,
    this.trackGainDb,
    this.trackPeak,
    this.albumGainDb,
    this.albumPeak,
  });

  final int id;
  final String filePath;
  final String title;
  final String artist;
  final String album;
  final Duration? duration;
  final double? trackGainDb;
  final double? trackPeak;
  final double? albumGainDb;
  final double? albumPeak;

  @override
  bool operator ==(Object other) =>
      other is AudioTrack && other.id == id && other.filePath == filePath;

  @override
  int get hashCode => Object.hash(id, filePath);
}

class SpectrumFrame {
  SpectrumFrame(Float32List magnitudes, {this.timestamp})
      : magnitudes = Float32List.fromList(magnitudes);

  final Float32List magnitudes;
  final Duration? timestamp;
}
