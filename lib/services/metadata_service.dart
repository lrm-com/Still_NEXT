import 'dart:io';

import 'package:metadata_god/metadata_god.dart';
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'audio/replay_gain.dart';

typedef MetadataReader = Future<Map<String, Object?>> Function(File file);

class MetadataService {
  const MetadataService({this.reader});
  final MetadataReader? reader;

  Future<Song> read(File file, {int? id, DateTime? addedAt}) async {
    final stat = await file.stat();
    final values = reader == null
        ? await _readEmbeddedMetadata(file)
        : await reader!(file);
    final stem = _stem(file.path);
    return Song(
      id: id ?? _stableId(file.path),
      path: file.path,
      title: _textOrFallback(values['title'], stem),
      artist: values['artist'] as String? ?? '',
      album: values['album'] as String? ?? '',
      albumArtist: values['albumArtist'] as String? ?? '',
      genre: values['genre'] as String? ?? '',
      year: values['year'] as int?,
      trackNumber: values['trackNumber'] as int?,
      duration: values['duration'] as Duration? ?? Duration.zero,
      fileSize: stat.size,
      format: _extension(file.path),
      bitrate: values['bitrate'] as int?,
      embeddedLyrics: values['lyrics'] as String?,
      coverArtPath: values['coverArtPath'] as String?,
      addedAt: addedAt ?? DateTime.now(),
      lastModified: stat.modified,
    );
  }

  static String _stem(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toUpperCase();
  }

  static String _textOrFallback(Object? value, String fallback) {
    final text = value as String?;
    return text == null || text.trim().isEmpty ? fallback : text.trim();
  }

  static int _stableId(String path) {
    var hash = 0x811c9dc5;
    for (final code in path.codeUnits) {
      hash ^= code;
      hash = (hash * 0x1000193) & 0x7fffffff;
    }
    return hash;
  }

  static Future<Map<String, Object?>> _readEmbeddedMetadata(File file) async {
    try {
      final metadata = await MetadataGod.readMetadata(file: file.path);
      String? coverArtPath;

      if (metadata.picture != null) {
        try {
          final picture = metadata.picture!;
          final appDir = await getApplicationSupportDirectory();
          final coversDir = Directory('${appDir.path}/covers');
          if (!await coversDir.exists()) await coversDir.create(recursive: true);
          final coverFile = File('${coversDir.path}/cover_${_stableId(file.path)}.jpg');
          await coverFile.writeAsBytes(picture.data);
          coverArtPath = coverFile.path;
        } catch (e) {
          // Cover extraction failed; continue without cover
        }
      }

      // metadata_god doesn't support lyrics; read via manual codec for mp3/flac
      String? lyrics;
      final ext = file.path.toLowerCase().split('.').last;
      if (ext == 'mp3' || ext == 'flac') {
        try {
          final tags = await const AudioTagEditor().read(file.path);
          lyrics = tags.lyrics;
        } catch (_) {
          // Manual tag read failed; continue without lyrics
        }
      }

      return <String, Object?>{
        'title': metadata.title,
        'artist': metadata.artist,
        'album': metadata.album,
        'albumArtist': metadata.albumArtist,
        'genre': metadata.genre,
        'year': metadata.year,
        'trackNumber': metadata.trackNumber,
        'duration': metadata.duration,
        'coverArtPath': coverArtPath,
        'lyrics': lyrics,
      };
    } catch (e) {
      // metadata_god failed; try manual codec as fallback for mp3/flac
      final ext = file.path.toLowerCase().split('.').last;
      if (ext == 'mp3' || ext == 'flac') {
        try {
          final tags = await const AudioTagEditor().read(file.path);
          return <String, Object?>{
            'title': tags.title,
            'artist': tags.artist,
            'album': tags.album,
            'albumArtist': tags.albumArtist,
            'genre': tags.genre,
            'year': tags.year,
            'trackNumber': tags.trackNumber,
            'lyrics': tags.lyrics,
          };
        } catch (_) {}
      }
      return const <String, Object?>{};
    }
  }
}
