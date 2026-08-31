import 'dart:async';

import 'package:flutter/services.dart';

enum DesktopWindowKind { main, lyrics, taskbarLyrics }

class LyricsWindowState {
  const LyricsWindowState(
      {this.title = '',
      this.artist = '',
      this.currentLine = '',
      this.nextLine = '',
      this.translation,
      this.position = Duration.zero,
      this.isPlaying = false,
      this.locked = false,
      this.opacity = 1});

  final String title;
  final String artist;
  final String currentLine;
  final String nextLine;
  final String? translation;
  final Duration position;
  final bool isPlaying;
  final bool locked;
  final double opacity;

  Map<String, Object?> toJson() => {
        'title': title,
        'artist': artist,
        'currentLine': currentLine,
        'nextLine': nextLine,
        'translation': translation,
        'positionMs': position.inMilliseconds,
        'isPlaying': isPlaying,
        'locked': locked,
        'opacity': opacity
      };

  factory LyricsWindowState.fromJson(Map<Object?, Object?> json) =>
      LyricsWindowState(
          title: json['title'] as String? ?? '',
          artist: json['artist'] as String? ?? '',
          currentLine: json['currentLine'] as String? ?? '',
          nextLine: json['nextLine'] as String? ?? '',
          translation: json['translation'] as String?,
          position:
              Duration(milliseconds: (json['positionMs'] as num? ?? 0).round()),
          isPlaying: json['isPlaying'] as bool? ?? false,
          locked: json['locked'] as bool? ?? false,
          opacity: (json['opacity'] as num? ?? 1).toDouble());
}

class DesktopWindowMessage {
  const DesktopWindowMessage(this.window, this.method, this.arguments);
  final DesktopWindowKind window;
  final String method;
  final Object? arguments;
}

class InProcessWindowBus {
  InProcessWindowBus._();
  static final instance = InProcessWindowBus._();
  final _controller =
      StreamController<DesktopWindowMessage>.broadcast(sync: true);
  Stream<DesktopWindowMessage> get messages => _controller.stream;
  void send(DesktopWindowMessage message) {
    if (!_controller.isClosed) _controller.add(message);
  }

  Future<void> dispose() => _controller.close();
}

class DesktopWindowService {
  DesktopWindowService({MethodChannel? channel, InProcessWindowBus? bus})
      : _channel = channel ?? const MethodChannel('still/desktop_windows'),
        _bus = bus ?? InProcessWindowBus.instance;

  final MethodChannel _channel;
  final InProcessWindowBus _bus;

  Future<void> show(DesktopWindowKind window) =>
      _invoke('show', {'window': window.name});
  Future<void> hide(DesktopWindowKind window) =>
      _invoke('hide', {'window': window.name});
  Future<void> close(DesktopWindowKind window) =>
      _invoke('close', {'window': window.name});
  Future<void> setLocked(bool locked) =>
      _invoke('setLocked', {'locked': locked});
  Future<void> setOpacity(double opacity) =>
      _invoke('setOpacity', {'opacity': opacity.clamp(0, 1)});

  Future<void> updateLyrics(LyricsWindowState state) async {
    final arguments = state.toJson();
    _bus.send(
        DesktopWindowMessage(DesktopWindowKind.lyrics, 'update', arguments));
    _bus.send(DesktopWindowMessage(
        DesktopWindowKind.taskbarLyrics, 'update', arguments));
    await _invoke('update', arguments);
  }

  Stream<LyricsWindowState> get lyricUpdates => _bus.messages
      .where((message) => message.method == 'update')
      .map((message) => LyricsWindowState.fromJson(
          (message.arguments as Map).cast<Object?, Object?>()));

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Flutter web/tests and unsupported desktop targets use the bus only.
    }
  }
}
