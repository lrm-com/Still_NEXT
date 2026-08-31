import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/database_service.dart';
import '../services/scanner_service.dart';

final databaseServiceProvider = Provider<DatabaseService>((_) => DatabaseService());
final scannerServiceProvider = Provider<ScannerService>((_) => ScannerService());
final libraryProvider = AsyncNotifierProvider<LibraryNotifier, List<Song>>(LibraryNotifier.new);

class LibraryNotifier extends AsyncNotifier<List<Song>> {
  @override
  Future<List<Song>> build() => ref.read(databaseServiceProvider).songs();

  Future<void> scan(Iterable<String> roots) async {
    state = const AsyncLoading();
    try {
      final songs = await ref.read(scannerServiceProvider).scan(roots);
      await ref.read(databaseServiceProvider).saveSongs(songs);
      state = AsyncData(songs);
    } catch (error, stack) {
      state = AsyncError(error, stack);
    }
  }
}
