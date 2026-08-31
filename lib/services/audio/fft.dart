import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_track.dart';

class RealFft {
  RealFft(this.size) {
    if (size < 2 || (size & (size - 1)) != 0) {
      throw ArgumentError.value(size, 'size', 'must be a power of two');
    }
    _window = Float32List.fromList([
      for (var index = 0; index < size; index++)
        (.5 * (1 - math.cos(2 * math.pi * index / (size - 1))))
    ]);
  }

  final int size;
  late final Float32List _window;

  Float32List magnitudes(Float32List input) {
    final real = Float64List(size);
    final imaginary = Float64List(size);
    final length = math.min(size, input.length);
    for (var index = 0; index < length; index++) {
      real[index] = input[index] * _window[index];
    }
    _transform(real, imaginary);
    final result = Float32List(size ~/ 2);
    final scale = 2 / size;
    for (var index = 0; index < result.length; index++) {
      final magnitude = math.sqrt(
              real[index] * real[index] + imaginary[index] * imaginary[index]) *
          scale;
      result[index] = (20 * math.log(magnitude + 1e-9) / math.ln10)
          .clamp(-120, 0)
          .toDouble();
    }
    return result;
  }

  void _transform(Float64List real, Float64List imaginary) {
    var j = 0;
    for (var index = 1; index < size; index++) {
      var bit = size >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (index < j) {
        final realValue = real[index];
        real[index] = real[j];
        real[j] = realValue;
      }
    }
    for (var length = 2; length <= size; length <<= 1) {
      final angle = -2 * math.pi / length;
      final stepReal = math.cos(angle);
      final stepImaginary = math.sin(angle);
      for (var start = 0; start < size; start += length) {
        var currentReal = 1.0;
        var currentImaginary = 0.0;
        final half = length ~/ 2;
        for (var offset = 0; offset < half; offset++) {
          final even = start + offset;
          final odd = even + half;
          final oddReal =
              real[odd] * currentReal - imaginary[odd] * currentImaginary;
          final oddImaginary =
              real[odd] * currentImaginary + imaginary[odd] * currentReal;
          final evenReal = real[even];
          final evenImaginary = imaginary[even];
          real[even] = evenReal + oddReal;
          imaginary[even] = evenImaginary + oddImaginary;
          real[odd] = evenReal - oddReal;
          imaginary[odd] = evenImaginary - oddImaginary;
          final nextReal =
              currentReal * stepReal - currentImaginary * stepImaginary;
          currentImaginary =
              currentReal * stepImaginary + currentImaginary * stepReal;
          currentReal = nextReal;
        }
      }
    }
  }
}

class SpectrumAnalyzer {
  SpectrumAnalyzer({this.windowSize = 1024, this.hopSize = 512})
      : _fft = RealFft(windowSize) {
    if (hopSize < 1 || hopSize > windowSize) {
      throw ArgumentError.value(hopSize, 'hopSize');
    }
  }

  final int windowSize;
  final int hopSize;
  final RealFft _fft;
  final List<double> _pending = [];
  int _sampleCount = 0;

  Iterable<SpectrumFrame> add(Float32List samples,
      {double sampleRate = 44100}) sync* {
    _pending.addAll(samples);
    while (_pending.length >= windowSize) {
      final window = Float32List.fromList(
          _pending.take(windowSize).toList(growable: false));
      yield SpectrumFrame(
        _fft.magnitudes(window),
        timestamp: Duration(
            microseconds: (_sampleCount * 1000000 / sampleRate).round()),
      );
      _pending.removeRange(0, hopSize);
      _sampleCount += hopSize;
    }
  }

  void reset() {
    _pending.clear();
    _sampleCount = 0;
  }
}
