import 'dart:async';

import '../core/utils/pinyin_utils.dart';
import '../models/song.dart';

enum SongSort { manual, titleAsc, titleDesc, artist, album, year, duration, addedAt, fileName }

class SearchService {
  const SearchService();

  List<Song> filterAndSort(Iterable<Song> source, {String query = '', SongSort sort = SongSort.addedAt}) {
    final filtered = source.where((song) => PinyinUtils.matches(query, [song.title, song.artist, song.album, song.fileName])).toList();
    filtered.sort((a, b) {
      int compare(String left, String right) => left.toLowerCase().compareTo(right.toLowerCase());
      switch (sort) {
        case SongSort.manual:
          return 0;
        case SongSort.titleAsc:
          return compare(a.title, b.title);
        case SongSort.titleDesc:
          return compare(b.title, a.title);
        case SongSort.artist:
          final result = compare(a.artist, b.artist);
          return result != 0 ? result : (a.year ?? 0).compareTo(b.year ?? 0);
        case SongSort.album:
          return compare(a.album, b.album);
        case SongSort.year:
          return (a.year ?? 0).compareTo(b.year ?? 0);
        case SongSort.duration:
          return a.duration.compareTo(b.duration);
        case SongSort.addedAt:
          return (b.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(a.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0));
        case SongSort.fileName:
          return compare(a.fileName, b.fileName);
      }
    });
    return List.unmodifiable(filtered);
  }
}

class DebouncedQuery {
  DebouncedQuery({this.delay = const Duration(milliseconds: 200)});
  final Duration delay;
  DateTime? _lastInput;

  Future<String> update(String value) async {
    final marker = DateTime.now();
    _lastInput = marker;
    await Future<void>.delayed(delay);
    return identical(_lastInput, marker) ? value : '';
  }
}

class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 200)});
  final Duration delay;
  Timer? _timer;

  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() => _timer?.cancel();
}
