import 'dart:async';

enum ShortcutAction {
  playPause,
  seekBackward,
  seekForward,
  previous,
  next,
  volumeUp,
  volumeDown,
  mute,
  fullscreen,
  lyrics,
  toggleTranslation,
  closeOverlay,
}

class ShortcutBinding {
  const ShortcutBinding(this.accelerator, this.action);
  final String accelerator;
  final ShortcutAction action;
}

/// Platform-neutral global shortcut registry. A desktop adapter can forward
/// native key events to [handle]; this class also works with Flutter key events.
class GlobalShortcutService {
  GlobalShortcutService({Iterable<ShortcutBinding>? bindings}) {
    for (final binding in bindings ?? defaultBindings) register(binding);
  }

  static const defaultBindings = <ShortcutBinding>[
    ShortcutBinding('Space', ShortcutAction.playPause),
    ShortcutBinding('Left', ShortcutAction.seekBackward),
    ShortcutBinding('Right', ShortcutAction.seekForward),
    ShortcutBinding('Up', ShortcutAction.previous),
    ShortcutBinding('Down', ShortcutAction.next),
    ShortcutBinding('Ctrl+Up', ShortcutAction.volumeUp),
    ShortcutBinding('Ctrl+Down', ShortcutAction.volumeDown),
    ShortcutBinding('Ctrl+M', ShortcutAction.mute),
    ShortcutBinding('F11', ShortcutAction.fullscreen),
    ShortcutBinding('Ctrl+F', ShortcutAction.lyrics),
    ShortcutBinding('Ctrl+L', ShortcutAction.lyrics),
    ShortcutBinding('Ctrl+T', ShortcutAction.toggleTranslation),
    ShortcutBinding('Escape', ShortcutAction.closeOverlay),
  ];

  final _actions = <String, ShortcutAction>{};
  final _listeners = <ShortcutAction, FutureOr<void> Function()>{};

  void register(ShortcutBinding binding) =>
      _actions[_normalize(binding.accelerator)] = binding.action;
  void unregister(String accelerator) => _actions.remove(_normalize(accelerator));
  void bind(ShortcutAction action, FutureOr<void> Function() callback) =>
      _listeners[action] = callback;
  ShortcutAction? actionFor(String accelerator) => _actions[_normalize(accelerator)];
  Map<String, ShortcutAction> get bindings => Map.unmodifiable(_actions);

  Future<bool> handle(String accelerator) async {
    final action = actionFor(accelerator);
    if (action == null) return false;
    final callback = _listeners[action];
    if (callback != null) await callback();
    return true;
  }

  static String _normalize(String value) {
    final parts = value.split('+').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    final modifiers = <String>{};
    String? key;
    for (final part in parts) {
      final p = part.toLowerCase();
      if (p == 'control' || p == 'ctrl') modifiers.add('Ctrl');
      else if (p == 'shift') modifiers.add('Shift');
      else if (p == 'alt') modifiers.add('Alt');
      else if (p == 'meta' || p == 'cmd' || p == 'command') modifiers.add('Meta');
      else key = part.length == 1 ? part.toUpperCase() : part;
    }
    return [...modifiers.toList()..sort(), if (key != null) key!].join('+');
  }
}
