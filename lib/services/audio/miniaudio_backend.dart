import 'dart:async';

import 'audio_engine_backend.dart';
import 'audio_track.dart';
import 'still_audio.dart';

/// [AudioEngineBackend] implementation backed by the miniaudio-based
/// native `still_audio.dll`.  Replaces [JustAudioBackend] on all platforms.
class MiniaudioBackend implements AudioEngineBackend {
  MiniaudioBackend({StillPlayer? player}) : _player = player ?? StillPlayer() {
    _subscriptions.add(_player.stateStream.listen(_onState));
    _subscriptions.add(_player.positionStream.listen(_onPosition));
    _subscriptions.add(_player.spectrumStream.listen(_onSpectrum));
  }

  final StillPlayer _player;
  final _events = StreamController<BackendEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _disposed = false;

  /// Direct access to the native player (for EQ, spectrum, etc.).
  StillPlayer get nativePlayer => _player;

  @override
  Stream<BackendEvent> get events => _events.stream;

  // ── Queue ──────────────────────────────────────────────────────────

  @override
  Future<void> setQueue(
    List<AudioTrack> tracks, {
    required int initialIndex,
    Duration initialPosition = Duration.zero,
  }) async {
    _ensureActive();
    if (tracks.isEmpty) {
      _player.stop();
      return;
    }

    final paths = tracks.map((t) => t.filePath).toList();
    print('[MiniaudioBackend] setQueue: ${paths.length} tracks, initialIndex: $initialIndex');
    _player.setQueue(paths);

    // Seek to initial position if requested.
    if (initialPosition > Duration.zero) {
      print('[MiniaudioBackend] setQueue: seeking to ${initialPosition.inMilliseconds}ms');
      _player.seek(initialPosition);
    }

    // If initial index is not 0, select it.
    if (initialIndex != 0) {
      print('[MiniaudioBackend] setQueue: seekToTrack($initialIndex)');
      _player.seekToTrack(initialIndex);
    }
  }

  // ── Playback ───────────────────────────────────────────────────────

  @override
  Future<void> play() async {
    _ensureActive();
    print('[MiniaudioBackend] play()');
    _player.play();
  }

  @override
  Future<void> pause() async {
    _ensureActive();
    _player.pause();
  }

  @override
  Future<void> stop() async {
    _ensureActive();
    _player.stop();
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    _ensureActive();
    if (index != null) {
      _player.seekToTrack(index);
    }
    _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    _ensureActive();
    _player.setVolume(volume);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _ensureActive();
    _player.setSpeed(speed);
  }

  @override
  Future<void> setLoopMode(BackendLoopMode mode) async {
    _ensureActive();
    final loopMode = switch (mode) {
      BackendLoopMode.off => StillLoopMode.off,
      BackendLoopMode.all => StillLoopMode.all,
      BackendLoopMode.one => StillLoopMode.one,
    };
    _player.setLoopMode(loopMode);
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    // Shuffle is managed by AudioEngine / PlaybackStateMachine;
    // the native player just plays tracks in order.
  }

  // ── Dispose ────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _player.dispose();
    await _events.close();
  }

  // ── Native callbacks → BackendEvent ────────────────────────────────

  void _onState(StillPlaybackStatus state) {
    print('[MiniaudioBackend] _onState: $state, currentIndex: ${_player.currentIndex}');
    if (_disposed) return;
    final status = switch (state) {
      StillPlaybackStatus.stopped   => BackendPlaybackStatus.idle,
      StillPlaybackStatus.loading   => BackendPlaybackStatus.loading,
      StillPlaybackStatus.playing   => BackendPlaybackStatus.playing,
      StillPlaybackStatus.paused    => BackendPlaybackStatus.paused,
      StillPlaybackStatus.seeking   => BackendPlaybackStatus.ready,
      StillPlaybackStatus.endOfList => BackendPlaybackStatus.completed,
    };
    _emit(BackendEvent.status(status, currentIndex: _player.currentIndex));
  }

  void _onPosition(StillPosition pos) {
    print('[MiniaudioBackend] _onPosition: ${pos.position.inMilliseconds}ms / ${pos.duration.inMilliseconds}ms');
    if (_disposed) return;
    _emit(BackendEvent.position(
      pos.position,
      bufferedPosition: pos.duration, // no separate buffer in miniaudio
    ));
    _emit(BackendEvent.duration(pos.duration));
  }

  void _onSpectrum(StillSpectrumFrame frame) {
    // Spectrum is handled by AudioEngine's spectrum subscription,
    // not via BackendEvent. This is a no-op here.
  }

  void _emit(BackendEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _ensureActive() {
    if (_disposed) throw StateError('MiniaudioBackend has been disposed');
  }
}
