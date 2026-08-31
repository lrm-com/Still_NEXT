import 'dart:async';

import 'package:flutter/services.dart';

enum MediaSessionAction { play, pause, next, previous, seek }

class MediaSessionMetadata {
  const MediaSessionMetadata(
      {required this.title,
      required this.artist,
      this.album = '',
      this.duration = Duration.zero,
      this.artworkPath});
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String? artworkPath;
  Map<String, Object?> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': duration.inMilliseconds,
        'artworkPath': artworkPath
      };
}

class MediaSessionService {
  MediaSessionService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('still/media_session');
  final MethodChannel _channel;
  final _actions = StreamController<MediaSessionAction>.broadcast();
  Stream<MediaSessionAction> get actions => _actions.stream;
  Future<void> setMetadata(MediaSessionMetadata metadata) =>
      _invoke('setMetadata', metadata.toJson());
  Future<void> setPlaybackState(
          {required bool playing,
          required Duration position,
          required double speed}) =>
      _invoke('setPlaybackState', {
        'playing': playing,
        'positionMs': position.inMilliseconds,
        'speed': speed
      });
  Future<void> clear() => _invoke('clear');
  void dispatch(MediaSessionAction action) {
    if (!_actions.isClosed) _actions.add(action);
  }

  Future<void> dispose() async {
    await _actions.close();
    await _invoke('dispose');
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {}
  }
}
