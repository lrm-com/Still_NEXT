import 'dart:convert';
import 'dart:io';

class PlaylistEntry {
  const PlaylistEntry(this.path, {this.title, this.artist, this.duration});
  final String path;
  final String? title;
  final String? artist;
  final Duration? duration;
  PlaylistEntry copyWith({String? title, String? artist, Duration? duration}) => PlaylistEntry(path, title: title ?? this.title, artist: artist ?? this.artist, duration: duration ?? this.duration);
  @override bool operator ==(Object other) => other is PlaylistEntry && other.path == path && other.title == title && other.artist == artist && other.duration == duration;
  @override int get hashCode => Object.hash(path, title, artist, duration);
}

enum PlaylistFormat { m3u, pls, xspf, fpl }

class PlaylistService {
  const PlaylistService();

  Future<List<PlaylistEntry>> importFile(File file, {PlaylistFormat? format}) async {
    final resolved = format ?? formatForPath(file.path);
    if (resolved == null) throw UnsupportedError('Unsupported playlist format: ${file.path}');
    return parse(await file.readAsString(), resolved, basePath: file.parent.path);
  }

  Future<void> exportFile(File file, Iterable<PlaylistEntry> entries, {PlaylistFormat? format, String? name}) async {
    final resolved = format ?? formatForPath(file.path);
    if (resolved == null) throw UnsupportedError('Unsupported playlist format: ${file.path}');
    await file.writeAsString(export(entries, resolved, name: name));
  }

  static PlaylistFormat? formatForPath(String path) {
    final extension = path.split(RegExp(r'[\\/.]')).last.toLowerCase();
    return switch (extension) {'m3u' || 'm3u8' => PlaylistFormat.m3u, 'pls' => PlaylistFormat.pls, 'xspf' => PlaylistFormat.xspf, 'fpl' => PlaylistFormat.fpl, _ => null};
  }
  List<PlaylistEntry> parseM3u(String content, {String? basePath}) => parse(content, PlaylistFormat.m3u, basePath: basePath);
  List<PlaylistEntry> parsePls(String content, {String? basePath}) => parse(content, PlaylistFormat.pls, basePath: basePath);
  List<PlaylistEntry> parseXspf(String content, {String? basePath}) => parse(content, PlaylistFormat.xspf, basePath: basePath);
  List<PlaylistEntry> parseFpl(String content, {String? basePath}) => parse(content, PlaylistFormat.fpl, basePath: basePath);

  List<PlaylistEntry> parse(String content, PlaylistFormat format, {String? basePath}) {
    final entries = switch (format) {
      PlaylistFormat.m3u => _parseM3u(content),
      PlaylistFormat.pls => _parsePls(content),
      PlaylistFormat.xspf => _parseXspf(content),
      PlaylistFormat.fpl => _parseFpl(content),
    };
    if (basePath == null || basePath.isEmpty) return List.unmodifiable(entries);
    return List.unmodifiable(entries.map((e) => e.path.isEmpty || _isAbsolute(e.path) ? e : PlaylistEntry(_join(basePath, e.path), title: e.title, artist: e.artist, duration: e.duration)));
  }

  String export(Iterable<PlaylistEntry> entries, PlaylistFormat format, {String? name}) => switch (format) {
        PlaylistFormat.m3u => _exportM3u(entries),
        PlaylistFormat.pls => _exportPls(entries),
        PlaylistFormat.xspf => _exportXspf(entries, name ?? 'Still playlist'),
        PlaylistFormat.fpl => _exportFpl(entries, name ?? 'Still playlist'),
      };

  static List<PlaylistEntry> _parseM3u(String source) {
    final result = <PlaylistEntry>[];
    String? title;
    String? artist;
    Duration? duration;
    for (final raw in source.replaceAll('\r', '').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#EXTM3U')) continue;
      if (line.startsWith('#EXTINF:')) {
        final match = RegExp(r'^#EXTINF:([-\d]+),(.*)$').firstMatch(line);
        if (match != null) {
          final seconds = int.tryParse(match.group(1)!);
          duration = seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
          final info = match.group(2)!;
          final split = info.split(' - ');
          artist = split.length > 1 ? split.first.trim() : null;
          title = split.length > 1 ? split.sublist(1).join(' - ').trim() : info.trim();
        }
        continue;
      }
      if (!line.startsWith('#')) { result.add(PlaylistEntry(line, title: title, artist: artist, duration: duration)); title = null; artist = null; duration = null; }
    }
    return result;
  }

  static List<PlaylistEntry> _parsePls(String source) {
    final values = <int, Map<String, String>>{};
    for (final raw in source.replaceAll('\r', '').split('\n')) {
      final match = RegExp(r'^File(\d+)|^Title(\d+)|^Length(\d+)', caseSensitive: false).firstMatch(raw.trim());
      final pair = raw.trim().split('=');
      if (match == null || pair.length < 2) continue;
      final index = int.tryParse(match.group(1) ?? match.group(2) ?? match.group(3)!);
      if (index != null) values.putIfAbsent(index, () => {})[raw.trim().substring(0, raw.indexOf('=')).toLowerCase()] = pair.sublist(1).join('=').trim();
    }
    final keys = values.keys.toList()..sort();
    return [for (final i in keys) if (values[i]!.keys.any((k) => k.startsWith('file'))) PlaylistEntry(values[i]!.entries.firstWhere((e) => e.key.startsWith('file')).value, title: values[i]!['title$i'], duration: _seconds(values[i]!['length$i']))];
  }

  static List<PlaylistEntry> _parseXspf(String source) {
    final result = <PlaylistEntry>[];
    for (final track in RegExp(r'<track\b[^>]*>(.*?)</track>', caseSensitive: false, dotAll: true).allMatches(source)) {
      final body = track.group(1)!;
      final location = _xmlValue(body, 'location');
      if (location == null || location.isEmpty) continue;
      final title = _xmlValue(body, 'title');
      final artist = _xmlValue(body, 'creator');
      final seconds = int.tryParse(_xmlValue(body, 'duration') ?? '');
      final decoded = Uri.decodeFull(location);
      final uri = Uri.tryParse(decoded);
      final path = uri != null && uri.scheme == 'file' ? uri.toFilePath() : decoded;
      result.add(PlaylistEntry(path, title: title, artist: artist, duration: seconds == null ? null : Duration(milliseconds: seconds)));
    }
    return result;
  }

  static List<PlaylistEntry> _parseFpl(String source) {
    final result = <PlaylistEntry>[];
    for (final match in RegExp(r'<(file|path|location)>(.*?)</\1>', caseSensitive: false, dotAll: true).allMatches(source)) result.add(PlaylistEntry(_unescapeXml(match.group(2)!.trim())));
    for (final match in RegExp(r'<entry\b([^>]*)/?>', caseSensitive: false).allMatches(source)) {
      final attrs = match.group(1)!;
      final path = _attribute(attrs, 'path') ?? _attribute(attrs, 'location');
      if (path != null && path.isNotEmpty && !result.any((e) => e.path == path)) result.add(PlaylistEntry(_unescapeXml(path), title: _attribute(attrs, 'title')));
    }
    return result;
  }

  static String _exportM3u(Iterable<PlaylistEntry> entries) => '#EXTM3U\n${entries.map((e) => '${e.duration == null ? '' : '#EXTINF:${e.duration!.inSeconds},${e.artist == null ? '' : '${e.artist} - '}${e.title ?? e.path}\n'}${e.path}').join('\n')}\n';
  static String _exportPls(Iterable<PlaylistEntry> entries) {
    final list = entries.toList(growable: false);
    final b = StringBuffer('[playlist]\nNumberOfEntries=${list.length}\nVersion=2\n');
    for (var i = 0; i < list.length; i++) { final e = list[i]; b.writeln('File${i + 1}=${e.path}'); if (e.title != null) b.writeln('Title${i + 1}=${e.title}'); if (e.duration != null) b.writeln('Length${i + 1}=${e.duration!.inSeconds}'); }
    return b.toString();
  }
  static String _exportXspf(Iterable<PlaylistEntry> entries, String name) => '<?xml version="1.0" encoding="UTF-8"?>\n<playlist version="1" xmlns="http://xspf.org/ns/0/"><title>${_escapeXml(name)}</title><trackList>${entries.map((e) => '<track><location>${_escapeXml(e.path)}</location>${e.title == null ? '' : '<title>${_escapeXml(e.title!)}</title>'}${e.artist == null ? '' : '<creator>${_escapeXml(e.artist!)}</creator>'}${e.duration == null ? '' : '<duration>${e.duration!.inMilliseconds}</duration>'}</track>').join()}</trackList></playlist>';
  static String _exportFpl(Iterable<PlaylistEntry> entries, String name) => '<foobar2000 version="1"><playlist name="${_escapeXml(name)}">${entries.map((e) => '<entry path="${_escapeXml(e.path)}"${e.title == null ? '' : ' title="${_escapeXml(e.title!)}"'}/>').join()}</playlist></foobar2000>';

  static Duration? _seconds(String? value) { final n = int.tryParse(value ?? ''); return n == null || n < 0 ? null : Duration(seconds: n); }
  static String? _xmlValue(String body, String tag) { final m = RegExp('<$tag\\b[^>]*>(.*?)</$tag>', caseSensitive: false, dotAll: true).firstMatch(body); return m == null ? null : _unescapeXml(m.group(1)!.trim()); }
  static String _escapeXml(String value) => const HtmlEscape(HtmlEscapeMode.element).convert(value);
  static String _unescapeXml(String value) => value.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&#39;', "'");
  static bool _isAbsolute(String value) => Uri.tryParse(value)?.isAbsolute ?? false;
  static String _join(String base, String child) => '$base${base.endsWith('/') || base.endsWith('\\') ? '' : '/'}$child';
  static String? _attribute(String attrs, String name) => RegExp('\\b$name\\s*=\\s*["\\\']([^"\\\']*)["\\\']', caseSensitive: false).firstMatch(attrs)?.group(1);
}
