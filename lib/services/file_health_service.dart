import 'dart:io';
import '../models/song.dart';

enum FileHealthIssue { missing, unreadable, metadataIncomplete }
class FileHealthReport {
  const FileHealthReport(this.song, this.issues);
  final Song song;
  final Set<FileHealthIssue> issues;
  bool get healthy => issues.isEmpty;
}

class FileHealthService {
  const FileHealthService();
  Future<FileHealthReport> inspect(Song song) async {
    final issues = <FileHealthIssue>{};
    final file = File(song.path);
    try {
      if (!await file.exists()) { issues.add(FileHealthIssue.missing); return FileHealthReport(song, Set.unmodifiable(issues)); }
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file || stat.size == 0) issues.add(FileHealthIssue.unreadable);
      try { await file.openRead(0, stat.size > 1 ? 1 : 0).drain(); } on Object { issues.add(FileHealthIssue.unreadable); }
    } on Object { issues.add(FileHealthIssue.unreadable); }
    if (song.title.trim().isEmpty || song.format.trim().isEmpty) issues.add(FileHealthIssue.metadataIncomplete);
    return FileHealthReport(song, Set.unmodifiable(issues));
  }
  Future<List<FileHealthReport>> inspectAll(Iterable<Song> songs) async => List.unmodifiable(await Future.wait(songs.map(inspect)));
  Future<List<FileHealthReport>> unhealthy(Iterable<Song> songs) async => (await inspectAll(songs)).where((r) => !r.healthy).toList(growable: false);
}
