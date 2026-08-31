import 'dart:io';

import '../core/utils/lrc_parser.dart';
import '../models/song.dart';
import 'lyrics_tools.dart';

class LyricsService {
  const LyricsService({this.parser = const LrcParser()});
  final LrcParser parser;

  Future<List<LyricsSource>> availableSources(Song song, {Iterable<LyricsSource> online = const []}) async {
    final sources = <LyricsSource>[];
    if (song.embeddedLyrics != null && song.embeddedLyrics!.trim().isNotEmpty) sources.add(const LyricsSource(type: LyricsSourceType.embedded, label: 'Embedded lyrics'));
    final lrc = File(song.path).path.replaceFirst(RegExp(r'\.[^.\\/]+$'), '.lrc');
    if (await File(lrc).exists()) sources.add(LyricsSource(type: LyricsSourceType.localFile, label: 'Local LRC', identifier: lrc));
    sources.addAll(online);
    return List.unmodifiable(sources);
  }

  LyricsDocument? loadEmbedded(Song song, {Duration offset = Duration.zero}) {
    final content = song.embeddedLyrics;
    return content == null || content.trim().isEmpty ? null : parser.parse(content, offset: offset);
  }

  Future<LyricsDocument?> load(Song song, {Duration offset = Duration.zero, LyricsSourceType? source}) async {
    if (source == LyricsSourceType.embedded || (source == null && song.embeddedLyrics != null && song.embeddedLyrics!.trim().isNotEmpty)) {
      return loadEmbedded(song, offset: offset);
    }
    if (source == LyricsSourceType.online) return null;
    final file = File(song.path);
    final lrc = file.path.replaceFirst(RegExp(r'\.[^.\\/]+$'), '.lrc');
    final translated = file.path.replaceFirst(RegExp(r'\.[^.\\/]+$'), '.translated.lrc');
    final fileSource = File(lrc);
    if (!await fileSource.exists()) return null;
    final document = parser.parse(await fileSource.readAsString(), offset: offset);
    if (!await File(translated).exists()) return document;
    final translations = parser.parse(await File(translated).readAsString());
    final lines = [
      for (var i = 0; i < document.lines.length; i++)
        LyricLine(document.lines[i].timestamp, document.lines[i].text, translation: i < translations.lines.length ? translations.lines[i].text : null, words: document.lines[i].words),
    ];
    return LyricsDocument(List.unmodifiable(lines), offset: offset, metadata: document.metadata);
  }
}
