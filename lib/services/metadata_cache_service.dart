import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

class MetadataCacheService {
  MetadataCacheService({SharedPreferences? preferences}) : _preferences = preferences;
  SharedPreferences? _preferences;
  static const _prefix = 'metadata:v2:';

  Future<void> _ensurePreferences() async {
    _preferences ??= await SharedPreferences.getInstance();
  }

  Future<Song?> read(String path, DateTime modified) async {
    await _ensurePreferences();
    final raw = _preferences!.getString(_key(path));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      if (json['lastModified'] != modified.toIso8601String()) return null;
      return Song.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(Song song) async {
    await _ensurePreferences();
    await _preferences!.setString(_key(song.path), jsonEncode(song.toJson()));
  }

  Future<void> remove(String path) async {
    await _ensurePreferences();
    await _preferences!.remove(_key(path));
  }

  Future<void> clear() async {
    await _ensurePreferences();
    for (final key in _preferences!.getKeys().where((key) => key.startsWith(_prefix)).toList()) {
      await _preferences!.remove(key);
    }
  }

  String _key(String path) => '$_prefix$path';
}
