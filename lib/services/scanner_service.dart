import 'dart:async';
import 'dart:io';

import '../models/song.dart';
import 'metadata_cache_service.dart';
import 'metadata_service.dart';

class ScanProgress {
  const ScanProgress(this.scanned, this.total, {this.currentPath});
  final int scanned;
  final int total;
  final String? currentPath;
  double get fraction => total == 0 ? 1 : (scanned / total).clamp(0, 1).toDouble();
}

class ScannerService {
  ScannerService({MetadataService? metadata, MetadataCacheService? cache})
      : _metadata = metadata ?? const MetadataService(),
        _cache = cache ?? MetadataCacheService();
  final MetadataService _metadata;
  final MetadataCacheService _cache;
  static const supportedExtensions = {'mp3', 'flac', 'm4a', 'aac', 'ogg', 'wav', 'opus', 'ape', 'wma', 'dsf', 'dff'};

  Future<List<Song>> scan(Iterable<String> roots, {void Function(ScanProgress)? onProgress}) async {
    final files = <File>[];
    final paths = <String>{};
    for (final root in roots) {
      final type = await FileSystemEntity.type(root, followLinks: false);
      if (type == FileSystemEntityType.file) {
        if (supportedExtensions.contains(_extension(root)) && paths.add(root)) {
          files.add(File(root));
        }
        continue;
      }
      if (type != FileSystemEntityType.directory) continue;
      try {
        await for (final entity in Directory(root).list(recursive: true, followLinks: false)) {
          if (entity is File &&
              supportedExtensions.contains(_extension(entity.path)) &&
              paths.add(entity.path)) {
            files.add(entity);
          }
        }
      } on FileSystemException {
        // A directory can become unavailable while it is being scanned.
      }
    }
    final songs = <Song>[];
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      try {
        final stat = await file.stat();
        final cached = await _cache.read(file.path, stat.modified);
        final song = cached ?? await _metadata.read(file);
        if (cached == null) await _cache.write(song);
        songs.add(song);
      } on FileSystemException {
        // A file can disappear while a library is being scanned.
      }
      onProgress?.call(ScanProgress(index + 1, files.length, currentPath: file.path));
    }
    songs.sort((a, b) => (a.title.toLowerCase()).compareTo(b.title.toLowerCase()));
    return List.unmodifiable(songs);
  }

  Stream<ScanProgress> scanProgress(Iterable<String> roots) async* {
    var latest = const ScanProgress(0, 0);
    await scan(roots, onProgress: (progress) => latest = progress);
    yield latest;
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }
}
