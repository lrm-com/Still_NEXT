import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_track.dart';
import 'biquad.dart';
import 'equalizer.dart';
import 'fft.dart';

/// Boundary for the future miniaudio Node Graph implementation.
///
/// It keeps realtime DSP outside the state machine and makes the native FFI
/// implementation replaceable without changing playback behavior.
abstract interface class AudioPostProcessor {
  Stream<SpectrumFrame> get spectrumFrames;

  Future<void> setEqualizer(EqualizerSettings settings);

  Future<void> setReplayGain(double gainDb);

  Future<void> fadeIn(Duration duration);

  Future<void> fadeOut(Duration duration);

  Future<void> dispose();
}

abstract interface class PcmAudioPostProcessor implements AudioPostProcessor {
  Float32List processPcm(
    Float32List samples, {
    required double sampleRate,
    required int channels,
  });
}

/// Functional fallback for platforms without a compiled miniaudio bridge.
/// It is also useful for tests and for a future decoder that exposes PCM.
class DspAudioPostProcessor implements PcmAudioPostProcessor {
  DspAudioPostProcessor({this.fftSize = 1024})
      : _spectrumController = StreamController<SpectrumFrame>.broadcast(),
        _analyzer = SpectrumAnalyzer(windowSize: fftSize);

  final int fftSize;
  final StreamController<SpectrumFrame> _spectrumController;
  final SpectrumAnalyzer _analyzer;
  EqualizerSettings _settings = EqualizerSettings.flat();
  EqualizerDsp? _equalizer;
  double _replayGainDb = 0;
  double _fade = 1;
  double _fadeStep = 0;
  bool _disposed = false;

  @override
  Stream<SpectrumFrame> get spectrumFrames => _spectrumController.stream;

  double get replayGainDb => _replayGainDb;

  @override
  Float32List processPcm(
    Float32List samples, {
    required double sampleRate,
    required int channels,
  }) {
    if (_disposed) throw StateError('AudioPostProcessor has been disposed');
    _equalizer ??= EqualizerDsp(
      sampleRate: sampleRate,
      channels: channels,
      settings: _settings,
    );
    final equalized = _equalizer!.process(samples);
    final gain = math.pow(10, _replayGainDb / 20).toDouble();
    for (var index = 0; index < equalized.length; index++) {
      if (_fadeStep != 0) {
        _fade = (_fade + _fadeStep).clamp(0, 1).toDouble();
        if (_fade == 0 || _fade == 1) _fadeStep = 0;
      }
      equalized[index] =
          (equalized[index] * gain * _fade).clamp(-1, 1).toDouble();
    }
    for (final frame in _analyzer.add(_toMono(equalized, channels),
        sampleRate: sampleRate)) {
      if (!_spectrumController.isClosed) _spectrumController.add(frame);
    }
    return equalized;
  }

  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {
    _settings = settings;
    _equalizer?.setSettings(settings);
  }

  @override
  Future<void> setReplayGain(double gainDb) async => _replayGainDb = gainDb;

  @override
  Future<void> fadeIn(Duration duration) async {
    if (duration <= Duration.zero) {
      _fade = 1;
      _fadeStep = 0;
    } else {
      _fade = 0;
      _fadeStep = 1 / (duration.inMicroseconds * 44.1);
    }
  }

  @override
  Future<void> fadeOut(Duration duration) async {
    if (duration <= Duration.zero) {
      _fade = 0;
      _fadeStep = 0;
    } else {
      _fadeStep = -1 / (duration.inMicroseconds * 44.1);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _spectrumController.close();
  }

  static Float32List _toMono(Float32List samples, int channels) {
    final safeChannels = channels < 1 ? 1 : channels;
    if (safeChannels == 1) return samples;
    final mono = Float32List((samples.length / safeChannels).ceil());
    for (var frame = 0; frame < mono.length; frame++) {
      var total = 0.0;
      var count = 0;
      for (var channel = 0; channel < safeChannels; channel++) {
        final index = frame * safeChannels + channel;
        if (index >= samples.length) break;
        total += samples[index];
        count++;
      }
      mono[frame] = count == 0 ? 0 : total / count;
    }
    return mono;
  }
}

/// Optional native bridge contract. If the DLL or symbols are absent, the
/// processor remains fully functional through [DspAudioPostProcessor].
class MiniaudioFfiAudioPostProcessor extends DspAudioPostProcessor {
  MiniaudioFfiAudioPostProcessor({super.fftSize, DynamicLibrary? library})
      : library = library ?? _tryOpen() {
    nativeAvailable = this.library != null;
  }

  final DynamicLibrary? library;
  late final bool nativeAvailable;

  static DynamicLibrary? _tryOpen() {
    final names = Platform.isWindows
        ? ['still_audio.dll', 'miniaudio.dll']
        : Platform.isMacOS
        ? ['libstill_audio.dylib', 'libminiaudio.dylib']
            : ['libstill_audio.so', 'libminiaudio.so'];
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } on Object {
        continue;
      }
    }
    return null;
  }
}

class NoOpAudioPostProcessor implements AudioPostProcessor {
  const NoOpAudioPostProcessor();

  @override
  Stream<SpectrumFrame> get spectrumFrames => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> fadeIn(Duration duration) async {}

  @override
  Future<void> fadeOut(Duration duration) async {}

  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {}

  @override
  Future<void> setReplayGain(double gainDb) async {}
}
