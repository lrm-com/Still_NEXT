import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/lrc_parser.dart';
import '../models/song.dart';
import '../services/lyrics_service.dart';

final lyricsServiceProvider = Provider<LyricsService>((_) => const LyricsService());
final lyricsProvider = FutureProvider.family<LyricsDocument?, Song>((ref, song) => ref.read(lyricsServiceProvider).load(song));
