import 'dart:async';

import 'audio_engine_backend.dart';
import 'audio_post_processor.dart';
import 'audio_track.dart';
import 'equalizer.dart';
import 'playback_state.dart';
import 'playback_state_machine.dart';
import 'replay_gain.dart';
import '../playback_memory_service.dart';

class AudioEngineSnapshot {
  const AudioEngineSnapshot({
    required this.playback,
    required this.equalizer,
    required this.replayGainSettings,
    this.position = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.duration,
    this.volume = 1,
    this.speed = 1,
    this.appliedReplayGainDb = 0,
    this.spectrum,
  });

  final PlaybackState<AudioTrack> playback;
  final Duration position;
  final Duration bufferedPosition;
  final Duration? duration;
  final double volume;
  final double speed;
  final EqualizerSettings equalizer;
  final ReplayGainSettings replayGainSettings;
  final double appliedReplayGainDb;
  final SpectrumFrame? spectrum;

  AudioTrack? get currentTrack => playback.currentTrack;

  AudioEngineSnapshot copyWith({
    PlaybackState<AudioTrack>? playback,
    Duration? position,
    Duration? bufferedPosition,
    Object? duration = _unchanged,
    double? volume,
    double? speed,
    EqualizerSettings? equalizer,
    ReplayGainSettings? replayGainSettings,
    double? appliedReplayGainDb,
    Object? spectrum = _unchanged,
  }) {
    return AudioEngineSnapshot(
      playback: playback ?? this.playback,
      position: position ?? this.position,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      duration: identical(duration, _unchanged)
          ? this.duration
          : duration as Duration?,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
      equalizer: equalizer ?? this.equalizer,
      replayGainSettings: replayGainSettings ?? this.replayGainSettings,
      appliedReplayGainDb: appliedReplayGainDb ?? this.appliedReplayGainDb,
      spectrum: identical(spectrum, _unchanged)
          ? this.spectrum
          : spectrum as SpectrumFrame?,
    );
  }

  static const Object _unchanged = Object();
}

/// Coordinates queue state, just_audio playback and miniaudio post-processing.
class AudioEngine {
  AudioEngine({
    required AudioEngineBackend backend,
    AudioPostProcessor? postProcessor,
    ReplayGainCalculator replayGainCalculator = const ReplayGainCalculator(),
    ReplayGainSettings replayGainSettings = const ReplayGainSettings(),
    EqualizerSettings? equalizerSettings,
    Duration fadeDuration = Duration.zero,
    ShuffleIndexGenerator? shuffleIndexGenerator,
    PlaybackMemoryService? playbackMemory,
  })  : _backend = backend,
        _postProcessor = postProcessor ?? MiniaudioFfiAudioPostProcessor(),
        _replayGainCalculator = replayGainCalculator,
        _fadeDuration = fadeDuration,
        _playbackMemory = playbackMemory,
        _machine = PlaybackStateMachine<AudioTrack>(
          shuffleIndexGenerator: shuffleIndexGenerator,
        ),
        _snapshot = AudioEngineSnapshot(
          playback: PlaybackState<AudioTrack>(),
          equalizer: equalizerSettings ?? EqualizerSettings.flat(),
          replayGainSettings: replayGainSettings,
        ) {
    _backendSubscription = _backend.events.listen(_handleBackendEvent);
    _spectrumSubscription = _postProcessor.spectrumFrames.listen(
      _handleSpectrumFrame,
    );
  }

  final AudioEngineBackend _backend;
  final AudioPostProcessor _postProcessor;
  final ReplayGainCalculator _replayGainCalculator;
  final Duration _fadeDuration;
  final PlaybackMemoryService? _playbackMemory;
  final PlaybackStateMachine<AudioTrack> _machine;
  final _snapshotController = StreamController<AudioEngineSnapshot>.broadcast(
    sync: true,
  );
  StreamSubscription<BackendEvent>? _backendSubscription;
  StreamSubscription<SpectrumFrame>? _spectrumSubscription;
  late AudioEngineSnapshot _snapshot;
  Future<void> _commands = Future<void>.value();
  bool _disposed = false;

  AudioEngineSnapshot get snapshot => _snapshot;
  Stream<AudioEngineSnapshot> get snapshots => _snapshotController.stream;

  /// Waits until all commands submitted so far have finished.
  Future<void> synchronize() => _commands;

  Future<void> initialize() => _run(() async {
        await _backend.setVolume(_snapshot.volume);
        await _backend.setSpeed(_snapshot.speed);
        await _postProcessor.setEqualizer(_snapshot.equalizer);
        final track = _machine.state.currentTrack;
        if (track != null) await _applyReplayGain(track);
        await _configureBackendMode(_machine.state.mode);
      });

  Future<void> loadQueue(
    Iterable<AudioTrack> tracks, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool autoplay = false,
  }) =>
      _run(() async {
        final queue = List<AudioTrack>.unmodifiable(tracks);
        if (queue.isEmpty) {
          _machine.clearQueue();
          await _backend.stop();
          _emit(
            _snapshot.copyWith(
              playback: _machine.state,
              position: Duration.zero,
              bufferedPosition: Duration.zero,
              duration: null,
              appliedReplayGainDb: 0,
              spectrum: null,
            ),
          );
          return;
        }
        _machine.replaceQueue(queue, currentIndex: initialIndex);
        if (initialPosition == Duration.zero && _playbackMemory != null) {
          initialPosition =
              (await _playbackMemory.load(queue[initialIndex].id))?.position ??
                  Duration.zero;
        }
        _machine.markLoading();
        _emit(
          _snapshot.copyWith(
            playback: _machine.state,
            position: initialPosition,
            bufferedPosition: Duration.zero,
            duration: queue[initialIndex].duration,
          ),
        );
        await _applyReplayGain(queue[initialIndex]);
        await _backend.setQueue(
          queue,
          initialIndex: initialIndex,
          initialPosition: initialPosition,
        );
        if (autoplay) {
          await _playNow();
        } else {
          _machine.stop();
          _emit(_snapshot.copyWith(playback: _machine.state));
        }
      });

  Future<void> play() => _run(_playNow);

  Future<void> pause() => _run(() async {
        if (!_machine.state.hasCurrentTrack) return;
        if (_fadeDuration > Duration.zero) {
          await _postProcessor.fadeOut(_fadeDuration);
        }
        await _backend.pause();
        final track = _machine.state.currentTrack;
        if (track != null)
          await _playbackMemory?.save(track.id, _snapshot.position);
        _machine.markPaused();
        _emit(_snapshot.copyWith(playback: _machine.state));
      });

  Future<void> stop() => _run(() async {
        if (_fadeDuration > Duration.zero) {
          await _postProcessor.fadeOut(_fadeDuration);
        }
        await _backend.stop();
        final track = _machine.state.currentTrack;
        if (track != null)
          await _playbackMemory?.save(track.id, _snapshot.position);
        _machine.stop();
        _emit(
          _snapshot.copyWith(
            playback: _machine.state,
            position: Duration.zero,
            bufferedPosition: Duration.zero,
          ),
        );
      });

  Future<void> seek(Duration position) => _run(() async {
        if (!_machine.state.hasCurrentTrack) return;
        final duration = _snapshot.duration;
        final target = position < Duration.zero
            ? Duration.zero
            : duration != null && position > duration
                ? duration
                : position;
        await _backend.seek(target);
        final track = _machine.state.currentTrack;
        if (track != null) await _playbackMemory?.save(track.id, target);
        _emit(_snapshot.copyWith(position: target));
      });

  Future<void> select(int index, {bool autoplay = true}) => _run(() async {
        final wasPlaying = _machine.state.isPlaying;
        _machine.select(index);
        _emitTrackChange();
        await _applyReplayGain(_machine.state.currentTrack!);
        await _backend.seek(Duration.zero, index: index);
        if (autoplay || wasPlaying) {
          await _playNow();
        } else {
          _machine.stop();
          _emit(_snapshot.copyWith(playback: _machine.state));
        }
      });

  Future<void> next() => _run(() => _navigate(forward: true));

  Future<void> previous() => _run(() async {
        if (_snapshot.position > const Duration(seconds: 3)) {
          await _backend.seek(Duration.zero);
          _emit(_snapshot.copyWith(position: Duration.zero));
          return;
        }
        await _navigate(forward: false);
      });

  Future<void> setMode(PlaybackMode mode) => _run(() async {
        _machine.setMode(mode);
        await _configureBackendMode(mode);
        _emit(_snapshot.copyWith(playback: _machine.state));
      });

  Future<void> setVolume(double volume) => _run(() async {
        final target = volume.clamp(0, 1).toDouble();
        await _backend.setVolume(target);
        _emit(_snapshot.copyWith(volume: target));
      });

  Future<void> setSpeed(double speed) => _run(() async {
        if (speed < 0.5 || speed > 2) {
          throw RangeError.value(speed, 'speed', 'must be between 0.5 and 2.0');
        }
        await _backend.setSpeed(speed);
        _emit(_snapshot.copyWith(speed: speed));
      });

  Future<void> setEqualizer(EqualizerSettings settings) => _run(() async {
        await _postProcessor.setEqualizer(settings);
        _emit(_snapshot.copyWith(equalizer: settings));
      });

  Future<void> setReplayGain(ReplayGainSettings settings) => _run(() async {
        _emit(_snapshot.copyWith(replayGainSettings: settings));
        final track = _machine.state.currentTrack;
        if (track != null) await _applyReplayGain(track);
      });

  Future<void> addToQueue(Iterable<AudioTrack> tracks) => _run(() async {
        _machine.addAll(tracks);
        await _reloadBackendQueue(preservePosition: true);
      });

  Future<void> removeFromQueueAt(int index) => _run(() async {
        final wasPlaying = _machine.state.isPlaying;
        final previousTrack = _machine.state.currentTrack;
        _machine.removeAt(index);
        final preservePosition = previousTrack == _machine.state.currentTrack;
        await _reloadBackendQueue(
          preservePosition: preservePosition,
          resumePlayback: wasPlaying,
        );
      });

  Future<void> moveQueueItem(int fromIndex, int toIndex) => _run(() async {
        _machine.move(fromIndex, toIndex);
        await _reloadBackendQueue(preservePosition: true);
      });

  Future<void> clearQueue() => loadQueue(const []);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _commands;
    await _backendSubscription?.cancel();
    await _spectrumSubscription?.cancel();
    await _backend.dispose();
    await _postProcessor.dispose();
    await _snapshotController.close();
  }

  Future<void> _playNow() async {
    if (!_machine.state.hasCurrentTrack) return;
    if (_machine.state.status == PlaybackStatus.completed) {
      await _backend.seek(Duration.zero, index: _machine.state.currentIndex);
      _emit(_snapshot.copyWith(position: Duration.zero));
    }
    await _backend.play();
    _machine.markPlaying();
    if (_fadeDuration > Duration.zero) {
      await _postProcessor.fadeIn(_fadeDuration);
    }
    _emit(_snapshot.copyWith(playback: _machine.state));
  }

  Future<void> _navigate({required bool forward}) async {
    if (!_machine.state.hasCurrentTrack) return;
    final wasPlaying = _machine.state.isPlaying;
    final wasPaused = _machine.state.isPaused;
    final nextState = forward ? _machine.next() : _machine.previous();
    if (nextState.status == PlaybackStatus.completed) {
      await _backend.stop();
      _emit(_snapshot.copyWith(playback: nextState));
      return;
    }
    if (nextState.status != PlaybackStatus.loading) return;

    _emitTrackChange();
    await _applyReplayGain(nextState.currentTrack!);
    await _backend.seek(Duration.zero, index: nextState.currentIndex);
    if (wasPlaying) {
      await _playNow();
    } else if (wasPaused) {
      _machine.markPaused();
      _emit(_snapshot.copyWith(playback: _machine.state));
    } else {
      _machine.stop();
      _emit(_snapshot.copyWith(playback: _machine.state));
    }
  }

  Future<void> _reloadBackendQueue({
    required bool preservePosition,
    bool? resumePlayback,
  }) async {
    final state = _machine.state;
    if (state.isEmpty) {
      await _backend.stop();
      _emit(
        _snapshot.copyWith(
          playback: state,
          position: Duration.zero,
          bufferedPosition: Duration.zero,
          duration: null,
          appliedReplayGainDb: 0,
        ),
      );
      return;
    }
    final wasPlaying = resumePlayback ?? state.isPlaying;
    final position = preservePosition ? _snapshot.position : Duration.zero;
    await _backend.setQueue(
      state.queue,
      initialIndex: state.currentIndex!,
      initialPosition: position,
    );
    await _applyReplayGain(state.currentTrack!);
    if (wasPlaying) await _backend.play();
    _emit(
      _snapshot.copyWith(
        playback: state,
        position: position,
        duration: state.currentTrack!.duration,
      ),
    );
  }

  Future<void> _applyReplayGain(AudioTrack track) async {
    final gain = _replayGainCalculator.gainFor(
      track,
      _snapshot.replayGainSettings,
    );
    await _postProcessor.setReplayGain(gain);
    _emit(_snapshot.copyWith(appliedReplayGainDb: gain));
  }

  Future<void> _configureBackendMode(PlaybackMode mode) async {
    final loopMode = switch (mode) {
      PlaybackMode.playlistLoop => BackendLoopMode.all,
      PlaybackMode.singleTrackLoop => BackendLoopMode.one,
      PlaybackMode.sequential || PlaybackMode.shuffle => BackendLoopMode.off,
    };
    await _backend.setLoopMode(loopMode);
    await _backend.setShuffleEnabled(mode == PlaybackMode.shuffle);
  }

  void _handleBackendEvent(BackendEvent event) {
    if (_disposed) return;
    if (event.error != null) {
      _machine.markError(event.error!);
      _emit(_snapshot.copyWith(playback: _machine.state));
      return;
    }
    if (event.currentIndex != null &&
        event.currentIndex != _machine.state.currentIndex &&
        event.currentIndex! < _machine.state.queue.length) {
      final previousStatus = _machine.state.status;
      _machine.markLoading(index: event.currentIndex);
      if (previousStatus == PlaybackStatus.playing) _machine.markPlaying();
      if (previousStatus == PlaybackStatus.paused) _machine.markPaused();
      if (previousStatus == PlaybackStatus.stopped) _machine.stop();
      _emitTrackChange();
      unawaited(_run(() => _applyReplayGain(_machine.state.currentTrack!)));
    }
    if (event.position != null) {
      _emit(
        _snapshot.copyWith(
          position: event.position,
          bufferedPosition: event.bufferedPosition,
        ),
      );
      final track = _machine.state.currentTrack;
      if (track != null)
        unawaited(_playbackMemory?.save(track.id, event.position!));
    } else if (event.duration != null) {
      _emit(_snapshot.copyWith(duration: event.duration));
    }
    final status = event.status;
    if (status == null) return;
    switch (status) {
      case BackendPlaybackStatus.idle:
        _machine.stop();
      case BackendPlaybackStatus.loading:
        _machine.markLoading();
      case BackendPlaybackStatus.ready:
      case BackendPlaybackStatus.paused:
        if (_machine.state.status == PlaybackStatus.playing ||
            _machine.state.status == PlaybackStatus.loading) {
          _machine.markPaused();
        }
      case BackendPlaybackStatus.playing:
        _machine.markPlaying();
      case BackendPlaybackStatus.completed:
        final nextState = _machine.onTrackCompleted();
        if (nextState.status == PlaybackStatus.loading) {
          unawaited(_resumeAfterCompletion());
        }
    }
    _emit(_snapshot.copyWith(playback: _machine.state));
  }

  Future<void> _resumeAfterCompletion() => _run(() async {
        final state = _machine.state;
        if (state.status != PlaybackStatus.loading ||
            state.currentIndex == null) {
          return;
        }
        _emitTrackChange();
        await _applyReplayGain(state.currentTrack!);
        await _backend.seek(Duration.zero, index: state.currentIndex);
        await _playNow();
      });

  void _handleSpectrumFrame(SpectrumFrame frame) {
    if (!_disposed) _emit(_snapshot.copyWith(spectrum: frame));
  }

  void _emitTrackChange() {
    _emit(
      _snapshot.copyWith(
        playback: _machine.state,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: _machine.state.currentTrack?.duration,
        spectrum: null,
      ),
    );
  }

  Future<void> _run(Future<void> Function() command) {
    _ensureActive();
    final result = _commands.then((_) => command());
    _commands = result.catchError((Object error, StackTrace stackTrace) {
      _machine.markError(error);
      _emit(_snapshot.copyWith(playback: _machine.state));
    });
    return result;
  }

  void _emit(AudioEngineSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) _snapshotController.add(snapshot);
  }

  void _ensureActive() {
    if (_disposed) throw StateError('AudioEngine has been disposed');
  }
}
