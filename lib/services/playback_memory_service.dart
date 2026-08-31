import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class PlaybackMemory {
  const PlaybackMemory({required this.position, this.updatedAt});
  final Duration position;
  final DateTime? updatedAt;
  Map<String, Object?> toJson() => {'positionMs': position.inMilliseconds, 'updatedAt': updatedAt?.toIso8601String()};
  factory PlaybackMemory.fromJson(Map<String, dynamic> json) => PlaybackMemory(position: Duration(milliseconds: (json['positionMs'] as num?)?.toInt() ?? 0), updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''));
}

class PlaybackMemoryService {
  PlaybackMemoryService({SharedPreferences? preferences, this.enabled = true}) : _preferences = preferences;
  SharedPreferences? _preferences;
  bool enabled;
  static const _prefix = 'playback.position.';
  Future<SharedPreferences> get _prefs async => _preferences ??= await SharedPreferences.getInstance();
  String _key(Object id) => '$_prefix$id';

  Future<void> save(Object trackId, Duration position) async {
    if (!enabled) return;
    final value = PlaybackMemory(position: position, updatedAt: DateTime.now());
    await (await _prefs).setString(_key(trackId), jsonEncode(value.toJson()));
  }
  Future<PlaybackMemory?> load(Object trackId) async {
    if (!enabled) return null;
    final raw = (await _prefs).getString(_key(trackId));
    if (raw == null) return null;
    try { return PlaybackMemory.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)); } on Object { return null; }
  }
  Future<void> clear(Object trackId) async => (await _prefs).remove(_key(trackId));
  Future<void> clearAll() async {
    final prefs = await _prefs;
    for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) await prefs.remove(key);
  }
}
