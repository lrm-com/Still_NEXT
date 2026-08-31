import 'package:flutter/services.dart';

import '../core/utils/lrc_parser.dart';
import '../models/song.dart';

enum LyricsCopyMode { original, originalAndTranslation, withSongInfo }

class LyricsCopyService {
  const LyricsCopyService();
  String format(LyricsDocument document, {LyricsCopyMode mode = LyricsCopyMode.original, Song? song}) {
    final lines = document.lines.map((line) {
      final translation = line.translation;
      if (mode == LyricsCopyMode.original) return line.text;
      if (mode == LyricsCopyMode.originalAndTranslation && translation != null && translation.isNotEmpty) return '${line.text}\n$translation';
      return translation == null || translation.isEmpty ? line.text : '${line.text}\n$translation';
    }).join('\n');
    if (mode != LyricsCopyMode.withSongInfo || song == null) return lines;
    return '${song.title}${song.artist.isEmpty ? '' : ' - ${song.artist}'}\n${song.album.isEmpty ? '' : '${song.album}\n'}\n$lines';
  }
  Future<void> copy(LyricsDocument document, {LyricsCopyMode mode = LyricsCopyMode.original, Song? song}) => Clipboard.setData(ClipboardData(text: format(document, mode: mode, song: song)));
}

enum LyricsSourceType { embedded, localFile, online }
class LyricsSource {
  const LyricsSource({required this.type, required this.label, this.identifier});
  final LyricsSourceType type;
  final String label;
  final String? identifier;
}

class LyricsSourceSelector {
  LyricsSourceSelector({Iterable<LyricsSource>? sources, LyricsSource? selected}) : _sources = List.unmodifiable(sources ?? const []), _selected = selected;
  final List<LyricsSource> _sources;
  LyricsSource? _selected;
  List<LyricsSource> get sources => _sources;
  LyricsSource? get selected => _selected;
  bool select(LyricsSourceType type, {String? identifier}) {
    final source = _sources.where((s) => s.type == type && (identifier == null || s.identifier == identifier)).firstOrNull;
    if (source == null) return false;
    _selected = source;
    return true;
  }
}

extension<T> on Iterable<T> { T? get firstOrNull => isEmpty ? null : first; }
