import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:still/services/audio/audio_post_processor.dart';
import 'package:still/services/audio/fft.dart';
import 'package:still/services/audio/equalizer.dart';
import 'package:still/services/audio/replay_gain.dart';

void main() {
  test('FFT returns a bounded logarithmic spectrum', () {
    final fft = RealFft(1024);
    final input = Float32List.fromList([
      for (var index = 0; index < 1024; index++)
        math.sin(2 * math.pi * 32 * index / 1024),
    ]);
    final spectrum = fft.magnitudes(input);
    expect(spectrum.length, 512);
    expect(spectrum.every((value) => value <= 0 && value >= -120), isTrue);
    expect(spectrum[32], greaterThan(spectrum[5]));
  });

  test('equalizer and replay gain process PCM samples', () async {
    final processor = DspAudioPostProcessor();
    await processor.setEqualizer(EqualizerSettingsPresetsHelper.boosted);
    await processor.setReplayGain(-6);
    final output = processor.processPcm(
        Float32List.fromList(List.filled(2048, .5)),
        sampleRate: 44100,
        channels: 1);
    expect(output.any((sample) => sample != .5), isTrue);
    await processor.dispose();
  });

  test('ReplayGain scanner reads PCM loudness and peak', () {
    final scanner = const ReplayGainScanner();
    final result = scanner.scanPcm(Float32List.fromList(List.filled(128, .5)),
        sampleRate: 44100, channels: 2);
    expect(result.trackPeak, closeTo(.5, .0001));
    expect(result.trackGainDb, closeTo(-11.2884, .001));
  });

  test('MP3 tag editor round trips text tags', () async {
    final directory = await Directory.systemTemp.createTemp('still_tags');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}track.mp3');
    await file.writeAsBytes([0xff, 0xfb, 0x90, 0x64, 0]);
    const editor = AudioTagEditor();
    await editor.write(
        file.path, const AudioTags(title: '标题', artist: '艺术家', year: 2026));
    final tags = await editor.read(file.path);
    expect(tags.title, '标题');
    expect(tags.artist, '艺术家');
    expect(tags.year, 2026);
  });
}

class EqualizerSettingsPresetsHelper {
  static final boosted = EqualizerSettings(
    gainsDb: {
      for (final band in EqualizerBand.values)
        band: band == EqualizerBand.hz1k ? 6 : 0
    },
  );
}
