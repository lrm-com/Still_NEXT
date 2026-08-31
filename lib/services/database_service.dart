import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// Small persistence boundary used by providers. The storage key layout mirrors
/// the Drift schema in SPEC.md, so it can be swapped for a generated Drift DB.
class DatabaseService {
  DatabaseService({SharedPreferences? preferences}) : _preferences = preferences;
  SharedPreferences? _preferences;
  static const _songsKey = 'db.songs';
  static const _foldersKey = 'db.folders';

  Future<SharedPreferences> get _prefs async => _preferences ??= await SharedPreferences.getInstance();

  Future<List<Song>> songs() async {
    final raw = (await _prefs).getString(_songsKey);
    if (raw == null) return const [];
    try {
      return List.unmodifiable((jsonDecode(raw) as List).map((e) => Song.fromJson(Map<String, Object?>.from(e as Map))));
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveSongs(Iterable<Song> songs) async {
    await (await _prefs).setString(_songsKey, jsonEncode(songs.map((song) => song.toJson()).toList()));
  }
  Future<List<String>> folders() async => (await _prefs).getStringList(_foldersKey) ?? const [];
  Future<void> saveFolders(Iterable<String> folders) async {
    await (await _prefs).setStringList(_foldersKey, folders.toList(growable: false));
  }
  Future<void> clear() async { final prefs = await _prefs; await prefs.remove(_songsKey); await prefs.remove(_foldersKey); }
}
