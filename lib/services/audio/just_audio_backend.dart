import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';

import 'audio_engine_backend.dart';
import 'audio_track.dart';
import 'local_media_server.dart';

class JustAudioBackend implements AudioEngineBackend {
  JustAudioBackend({AudioPlayer? player})
      : _player = player ?? AudioPlayer() {
    _subscriptions.add(_player.playerStateStream.listen(_onPlayerState));
    _subscriptions.add(
      _player.positionStream.listen((position) {
        _emit(
          BackendEvent.position(
            position,
            bufferedPosition: _player.bufferedPosition,
          ),
        );
      }),
    );
    _subscriptions.add(
      _player.durationStream.listen((duration) {
        _emit(BackendEvent.duration(duration));
      }),
    );
    _subscriptions.add(
      _player.currentIndexStream.listen((index) {
        _emit(BackendEvent.index(index));
      }),
    );
    _subscriptions.add(
      _player.errorStream.listen((error) {
        print('[JustAudioBackend] Error stream: $error');
        _emit(BackendEvent.error(error));
      }),
    );
    _serverReady = LocalMediaServer.instance.start();
  }

  final AudioPlayer _player;
  final _events = StreamController<BackendEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  late final Future<void> _serverReady;
  bool _disposed = false;

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  Future<void> setQueue(
    List<AudioTrack> tracks, {
    required int initialIndex,
    Duration initialPosition = Duration.zero,
  }) async {
    _ensureActive();
    await _serverReady;
    final sources = <AudioSource>[];
    for (final track in tracks) {
      try {
        final file = File(track.filePath);
        if (await file.exists()) {
          final uri = LocalMediaServer.instance.fileToUri(track.filePath);
          print('[JustAudioBackend] URI: $uri');
          sources.add(AudioSource.uri(uri));
        } else {
          print('[JustAudioBackend] File not found: ${track.filePath}');
          sources.add(AudioSource.uri(Uri.parse('')));
        }
      } catch (e) {
        print('[JustAudioBackend] Error creating source: $e');
        sources.add(AudioSource.uri(Uri.parse('')));
      }
    }
    print('[JustAudioBackend] Setting ${sources.length} audio sources, initialIndex: $initialIndex');
    await _player.setAudioSources(
      sources,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
    print('[JustAudioBackend] Audio sources set successfully');
  }

  @override
  Future<void> play() {
    print('[JustAudioBackend] play() called, currentIndex: ${_player.currentIndex}');
    return _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position, {int? index}) =>
      _player.seek(position, index: index);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setLoopMode(BackendLoopMode mode) {
    final loopMode = switch (mode) {
      BackendLoopMode.off => LoopMode.off,
      BackendLoopMode.all => LoopMode.all,
      BackendLoopMode.one => LoopMode.one,
    };
    return _player.setLoopMode(loopMode);
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    if (enabled) await _player.shuffle();
    await _player.setShuffleModeEnabled(enabled);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _events.close();
    await LocalMediaServer.instance.stop();
  }

  void _onPlayerState(PlayerState playerState) {
    final status = switch (playerState.processingState) {
      ProcessingState.idle => BackendPlaybackStatus.idle,
      ProcessingState.loading ||
      ProcessingState.buffering =>
        BackendPlaybackStatus.loading,
      ProcessingState.ready when playerState.playing =>
        BackendPlaybackStatus.playing,
      ProcessingState.ready => BackendPlaybackStatus.ready,
      ProcessingState.completed => BackendPlaybackStatus.completed,
    };
    _emit(BackendEvent.status(status, currentIndex: _player.currentIndex));
  }

  void _emit(BackendEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _ensureActive() {
    if (_disposed) throw StateError('JustAudioBackend has been disposed');
  }
}
