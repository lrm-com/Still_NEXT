import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class WindowStateService {
  WindowStateService({SharedPreferences? preferences}) : _preferences = preferences;
  SharedPreferences? _preferences;
  Future<SharedPreferences> get _prefs async => _preferences ??= await SharedPreferences.getInstance();

  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    final prefs = await _prefs;
    final size = SizeValue(prefs.getDouble('window.width') ?? 1280, prefs.getDouble('window.height') ?? 800);
    final options = WindowOptions(size: size.toSize(), minimumSize: const SizeValue(1024, 640).toSize(), center: true, titleBarStyle: TitleBarStyle.hidden);
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.show();
      await windowManager.focus();
      if (prefs.getBool('window.maximized') ?? false) await windowManager.maximize();
    });
  }

  Future<void> persist() async {
    final prefs = await _prefs;
    final size = await windowManager.getSize();
    await prefs.setDouble('window.width', size.width);
    await prefs.setDouble('window.height', size.height);
    await prefs.setBool('window.maximized', await windowManager.isMaximized());
  }
}

class SizeValue {
  const SizeValue(this.width, this.height);
  final double width;
  final double height;
  Size toSize() => Size(width, height);
}
