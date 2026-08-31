class LyricLine {
  const LyricLine(this.timestamp, this.text, {this.translation, this.words = const []});
  final Duration timestamp;
  final String text;
  final String? translation;
  final List<LyricWord> words;
}

class LyricWord {
  const LyricWord(this.timestamp, this.text);
  final Duration timestamp;
  final String text;
}

class LyricsDocument {
  const LyricsDocument(this.lines, {this.offset = Duration.zero, this.metadata = const {}});
  final List<LyricLine> lines;
  final Duration offset;
  final Map<String, String> metadata;

  LyricLine? lineAt(Duration position) {
    LyricLine? result;
    final adjusted = position - offset;
    for (final line in lines) {
      if (line.timestamp <= adjusted) result = line;
      else break;
    }
    return result;
  }
}

/// Parses standard LRC, extended millisecond timestamps and common YRC word tags.
class LrcParser {
  const LrcParser();

  LyricsDocument parse(String source, {Duration offset = Duration.zero}) {
    final lines = <LyricLine>[];
    final metadata = <String, String>{};
    final timestamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final wordTag = RegExp(r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>([^<]*)');
    for (final raw in source.replaceAll('\r', '').split('\n')) {
      final tags = timestamp.allMatches(raw).toList(growable: false);
      if (tags.isEmpty) {
        final meta = RegExp(r'^\[([a-zA-Z]+):([^\]]*)\]').firstMatch(raw);
        if (meta != null) metadata[meta.group(1)!.toLowerCase()] = meta.group(2)!.trim();
        continue;
      }
      final text = raw.substring(tags.last.end).trim();
      final words = [
        for (final match in wordTag.allMatches(text))
          LyricWord(_parseTime(match.group(1)!, match.group(2)!, match.group(3)), match.group(4)!),
      ];
      for (final tag in tags) {
        lines.add(LyricLine(_parseTime(tag.group(1)!, tag.group(2)!, tag.group(3)), text, words: words));
      }
    }
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final metadataOffset = int.tryParse(metadata['offset'] ?? '0') ?? 0;
    final effectiveOffset = offset == Duration.zero ? Duration(milliseconds: metadataOffset) : offset;
    return LyricsDocument(List.unmodifiable(lines), offset: effectiveOffset, metadata: Map.unmodifiable(metadata));
  }

  static Duration _parseTime(String minute, String second, String? fraction) {
    final fractionText = fraction ?? '0';
    final millis = switch (fractionText.length) {
      1 => int.parse(fractionText) * 100,
      2 => int.parse(fractionText) * 10,
      _ => int.parse(fractionText.substring(0, 3)),
    };
    return Duration(minutes: int.parse(minute), seconds: int.parse(second), milliseconds: millis);
  }
}
