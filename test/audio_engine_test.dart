import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'package:still/services/audio/audio_engine.dart';
import 'package:still/services/audio/audio_engine_backend.dart';
import 'package:still/services/audio/audio_post_processor.dart';
import 'package:still/services/audio/audio_track.dart';
import 'package:still/services/audio/equalizer.dart';
import 'package:still/services/audio/playback_state.dart';
import 'package:still/services/audio/replay_gain.dart';

Future<void> main() async {
  test('coordinates playback, queue state and backend errors',
      _testPlaybackCoordination);
  test('handles loop modes and completion events', _testLoopAndCompletion);
  test('prevents ReplayGain clipping', _testReplayGainClipping);
}

Future<void> _testPlaybackCoordination() async {
  final backend = _FakeBackend();
  final processor = _FakePostProcessor();
  final engine = AudioEngine(
    backend: backend,
    postProcessor: processor,
    fadeDuration: const Duration(milliseconds: 100),
    replayGainSettings: const ReplayGainSettings(
      mode: ReplayGainMode.track,
      preampDb: 3,
    ),
  );
  final tracks = [
    _track(1, gain: -6),
    _track(2, gain: -4),
    _track(3, gain: -2),
  ];

  await engine.initialize();
  await engine.loadQueue(tracks, autoplay: true);
  _expect(engine.snapshot.playback.isPlaying, 'Autoplay must enter playing.');
  _expect(backend.queue.length == 3, 'The gapless queue was not loaded.');
  _expect(processor.replayGainDb == -3, 'Track ReplayGain was not applied.');
  _expect(processor.fadeInCalls == 1, 'Fade-in was not requested.');

  backend.emit(BackendEvent.position(const Duration(seconds: 5)));
  await engine.previous();
  _expect(
    backend.lastSeek == const _SeekCall(Duration.zero, null),
    'Previous after three seconds must restart the current track.',
  );

  await engine.next();
  _expect(engine.snapshot.currentTrack == tracks[1], 'Next did not advance.');
  _expect(backend.lastSeek?.index == 1, 'Backend index did not follow state.');

  backend.emit(BackendEvent.error(StateError('decoder failed')));
  _expect(
    engine.snapshot.playback.status == PlaybackStatus.error,
    'Backend errors must enter the error state.',
  );
  await engine.play();
  _expect(
    engine.snapshot.playback.status == PlaybackStatus.playing,
    'A new play command must recover from an error.',
  );

  await engine.dispose();
}

Future<void> _testLoopAndCompletion() async {
  final backend = _FakeBackend();
  final engine = AudioEngine(backend: backend);
  final tracks = [_track(1), _track(2), _track(3)];

  await engine.loadQueue(tracks, initialIndex: 2, autoplay: true);
  await engine.setMode(PlaybackMode.playlistLoop);
  await engine.next();
  _expect(
    engine.snapshot.currentTrack == tracks[0],
    'Playlist loop must wrap.',
  );
  _expect(backend.loopMode == BackendLoopMode.all, 'Loop mode was not synced.');

  await engine.setMode(PlaybackMode.singleTrackLoop);
  await engine.select(1);
  final playCount = backend.playCount;
  backend.emit(BackendEvent.status(BackendPlaybackStatus.completed));
  await engine.synchronize();
  _expect(
    engine.snapshot.currentTrack == tracks[1],
    'Single loop changed tracks.',
  );
  _expect(
    backend.lastSeek?.index == 1,
    'Single loop did not rewind the track.',
  );
  _expect(
    backend.playCount > playCount,
    'Single loop did not resume playback.',
  );
  _expect(
    backend.loopMode == BackendLoopMode.one,
    'Single loop was not synced.',
  );

  await engine.dispose();
}

void _testReplayGainClipping() {
  final gain = const ReplayGainCalculator().gainFor(
    _track(1, gain: 6, peak: 2),
    const ReplayGainSettings(mode: ReplayGainMode.track),
  );
  _expect(gain < -6 && gain > -6.1, 'Clipping prevention is incorrect.');
}

AudioTrack _track(int id, {double? gain, double? peak}) => AudioTrack(
      id: id,
      filePath: 'C:/Music/$id.flac',
      title: 'Track $id',
      duration: const Duration(minutes: 3),
      trackGainDb: gain,
      trackPeak: peak,
    );

class _FakeBackend implements AudioEngineBackend {
  final _events = StreamController<BackendEvent>.broadcast(sync: true);
  List<AudioTrack> queue = const [];
  int playCount = 0;
  _SeekCall? lastSeek;
  BackendLoopMode loopMode = BackendLoopMode.off;
  bool shuffleEnabled = false;

  @override
  Stream<BackendEvent> get events => _events.stream;

  void emit(BackendEvent event) => _events.add(event);

  @override
  Future<void> setQueue(
    List<AudioTrack> tracks, {
    required int initialIndex,
    Duration initialPosition = Duration.zero,
  }) async {
    queue = List.unmodifiable(tracks);
    lastSeek = _SeekCall(initialPosition, initialIndex);
  }

  @override
  Future<void> play() async {
    playCount++;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position, {int? index}) async {
    lastSeek = _SeekCall(position, index);
  }

  @override
  Future<void> setLoopMode(BackendLoopMode mode) async {
    loopMode = mode;
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    shuffleEnabled = enabled;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() => _events.close();
}

class _FakePostProcessor implements AudioPostProcessor {
  double replayGainDb = 0;
  int fadeInCalls = 0;
  int fadeOutCalls = 0;
  EqualizerSettings equalizer = EqualizerSettings.flat();

  @override
  Stream<SpectrumFrame> get spectrumFrames => const Stream.empty();

  @override
  Future<void> setReplayGain(double gainDb) async {
    replayGainDb = gainDb;
  }

  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {
    equalizer = settings;
  }

  @override
  Future<void> fadeIn(Duration duration) async {
    fadeInCalls++;
  }

  @override
  Future<void> fadeOut(Duration duration) async {
    fadeOutCalls++;
  }

  @override
  Future<void> dispose() async {}
}

class _SeekCall {
  const _SeekCall(this.position, this.index);

  final Duration position;
  final int? index;

  @override
  bool operator ==(Object other) =>
      other is _SeekCall && other.position == position && other.index == index;

  @override
  int get hashCode => Object.hash(position, index);
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
