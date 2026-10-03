import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio/audio_engine.dart';
import '../services/audio/miniaudio_backend.dart';

final audioEngineProvider = Provider<AudioEngine>((ref) {
  final engine = AudioEngine(backend: MiniaudioBackend());
  ref.onDispose(engine.dispose);
  engine.initialize();
  return engine;
});
