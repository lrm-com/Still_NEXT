import 'dart:async';

import 'audio_track.dart';

enum BackendPlaybackStatus { idle, loading, ready, playing, paused, completed }

enum BackendLoopMode { off, all, one }

class BackendEvent {
  const BackendEvent._({
    this.status,
    this.currentIndex,
    this.position,
    this.duration,
    this.bufferedPosition,
    this.error,
  });

  factory BackendEvent.status(
    BackendPlaybackStatus status, {
    int? currentIndex,
  }) =>
      BackendEvent._(status: status, currentIndex: currentIndex);

  factory BackendEvent.position(
    Duration position, {
    Duration? bufferedPosition,
  }) =>
      BackendEvent._(position: position, bufferedPosition: bufferedPosition);

  factory BackendEvent.duration(Duration? duration) =>
      BackendEvent._(duration: duration);

  factory BackendEvent.index(int? currentIndex) =>
      BackendEvent._(currentIndex: currentIndex);

  factory BackendEvent.error(Object error) => BackendEvent._(error: error);

  final BackendPlaybackStatus? status;
  final int? currentIndex;
  final Duration? position;
  final Duration? duration;
  final Duration? bufferedPosition;
  final Object? error;
}

/// Boundary between the playback state machine and the decoder/output plugin.
abstract interface class AudioEngineBackend {
  Stream<BackendEvent> get events;

  Future<void> setQueue(
    List<AudioTrack> tracks, {
    required int initialIndex,
    Duration initialPosition = Duration.zero,
  });

  Future<void> play();

  Future<void> pause();

  Future<void> stop();

  Future<void> seek(Duration position, {int? index});

  Future<void> setVolume(double volume);

  Future<void> setSpeed(double speed);

  Future<void> setLoopMode(BackendLoopMode mode);

  Future<void> setShuffleEnabled(bool enabled);

  Future<void> dispose();
}
