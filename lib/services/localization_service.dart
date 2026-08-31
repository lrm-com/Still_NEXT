import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class StillLocalizations {
  StillLocalizations(this.locale);
  final String locale;
  static const _strings = <String, Map<String, String>>{
    'en': {'songs': 'Songs', 'artists': 'Artists', 'albums': 'Albums', 'playlists': 'Playlists', 'settings': 'Settings', 'play': 'Play', 'pause': 'Pause', 'noLyrics': 'No lyrics'},
    'zh': {'songs': '歌曲', 'artists': '艺术家', 'albums': '专辑', 'playlists': '歌单', 'settings': '设置', 'play': '播放', 'pause': '暂停', 'noLyrics': '暂无歌词'},
  };
  String text(String key, {String? fallback}) => _strings[_language]?[key] ?? fallback ?? _strings['en']![key] ?? key;
  String get _language => locale.toLowerCase().split(RegExp('[-_]')).first;
  static StillLocalizations of(String locale) => StillLocalizations(locale);
}

class LocaleService {
  LocaleService({String initialLocale = 'zh-CN'}) : _locale = initialLocale;
  String _locale;
  final _changes = StreamController<String>.broadcast();
  String get locale => _locale;
  Stream<String> get changes => _changes.stream;
  StillLocalizations get localizations => StillLocalizations(_locale);
  Future<void> setLocale(String locale) async { if (locale.trim().isEmpty || locale == _locale) return; _locale = locale; _changes.add(locale); }
  Future<void> dispose() => _changes.close();
}

class StillLocalizationsDelegate extends LocalizationsDelegate<StillLocalizations> {
  const StillLocalizationsDelegate();
  @override bool isSupported(Locale locale) => const ['en', 'zh'].contains(locale.languageCode);
  @override Future<StillLocalizations> load(Locale locale) => SynchronousFuture(StillLocalizations(locale.toLanguageTag()));
  @override bool shouldReload(covariant StillLocalizationsDelegate old) => false;
}
