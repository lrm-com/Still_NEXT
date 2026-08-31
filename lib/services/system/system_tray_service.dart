import 'dart:async';

import 'package:flutter/services.dart';

enum TrayAction {
  showWindow,
  playPause,
  previous,
  next,
  toggleLyrics,
  toggleTaskbarLyrics,
  exit
}

class TrayMenuItem {
  const TrayMenuItem(this.action, this.label, {this.enabled = true});
  final TrayAction action;
  final String label;
  final bool enabled;
  Map<String, Object?> toJson() =>
      {'action': action.name, 'label': label, 'enabled': enabled};
}

class SystemTrayService {
  SystemTrayService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('still/system_tray');
  final MethodChannel _channel;
  final _actions = StreamController<TrayAction>.broadcast();
  Stream<TrayAction> get actions => _actions.stream;

  Future<void> initialize(
      {required String tooltip, required List<TrayMenuItem> menu}) async {
    await _invoke('initialize', {
      'tooltip': tooltip,
      'menu': menu.map((item) => item.toJson()).toList()
    });
  }

  Future<void> setTooltip(String tooltip) => _invoke('setTooltip', tooltip);
  Future<void> setPlaying(bool playing) => _invoke('setPlaying', playing);
  Future<void> dispose() async {
    await _actions.close();
    await _invoke('dispose');
  }

  void dispatch(TrayAction action) {
    if (!_actions.isClosed) _actions.add(action);
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {}
  }
}
