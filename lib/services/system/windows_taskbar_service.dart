import 'dart:io';

import 'package:flutter/services.dart';

class WindowsTaskbarService {
  WindowsTaskbarService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('still/windows_taskbar');
  final MethodChannel _channel;
  bool get isSupported => Platform.isWindows;
  Future<void> setTitle(String title) => _invoke('setTitle', title);
  Future<void> setProgress({required double value, bool error = false}) =>
      _invoke('setProgress', {'value': value.clamp(0, 1), 'error': error});
  Future<void> clearProgress() => _invoke('clearProgress');
  Future<void> setThumbnailButtons({required bool playing}) => _invoke(
      'setThumbnailButtons',
      {'playing': playing, 'previous': true, 'next': true});
  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {}
  }
}
