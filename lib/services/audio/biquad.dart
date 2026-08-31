import 'dart:math' as math;
import 'dart:typed_data';

import 'equalizer.dart';

enum BiquadType { peaking, lowShelf, highShelf }

class BiquadCoefficients {
  const BiquadCoefficients({
    required this.b0,
    required this.b1,
    required this.b2,
    required this.a1,
    required this.a2,
  });

  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;
}

/// RBJ cookbook biquad filter. State is kept separately per audio channel.
class BiquadFilter {
  BiquadFilter({BiquadCoefficients? coefficients})
      : _coefficients = coefficients ?? _identity;

  static const _identity = BiquadCoefficients(
    b0: 1,
    b1: 0,
    b2: 0,
    a1: 0,
    a2: 0,
  );

  BiquadCoefficients _coefficients;
  double _x1 = 0;
  double _x2 = 0;
  double _y1 = 0;
  double _y2 = 0;

  BiquadCoefficients get coefficients => _coefficients;

  void configure({
    required BiquadType type,
    required double frequencyHz,
    required double gainDb,
    required double sampleRate,
    double q = 1,
  }) {
    if (gainDb.abs() < 1e-9) {
      _coefficients = _identity;
      return;
    }
    final safeSampleRate = math.max(1, sampleRate);
    final frequency = frequencyHz.clamp(1, safeSampleRate * .49).toDouble();
    final omega = 2 * math.pi * frequency / safeSampleRate;
    final alpha = math.sin(omega) / (2 * math.max(.01, q));
    final cosine = math.cos(omega);
    final sine = math.sin(omega);
    final amplitude = math.pow(10, gainDb / 40).toDouble();
    final beta = 2 * math.sqrt(amplitude) * alpha;

    late double b0;
    late double b1;
    late double b2;
    late double a0;
    late double a1;
    late double a2;
    switch (type) {
      case BiquadType.peaking:
        b0 = 1 + alpha * amplitude;
        b1 = -2 * cosine;
        b2 = 1 - alpha * amplitude;
        a0 = 1 + alpha / amplitude;
        a1 = -2 * cosine;
        a2 = 1 - alpha / amplitude;
      case BiquadType.lowShelf:
        b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + beta);
        b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine);
        b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - beta);
        a0 = (amplitude + 1) + (amplitude - 1) * cosine + beta;
        a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosine);
        a2 = (amplitude + 1) + (amplitude - 1) * cosine - beta;
      case BiquadType.highShelf:
        b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + beta);
        b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine);
        b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - beta);
        a0 = (amplitude + 1) - (amplitude - 1) * cosine + beta;
        a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosine);
        a2 = (amplitude + 1) - (amplitude - 1) * cosine - beta;
    }
    _coefficients = BiquadCoefficients(
      b0: b0 / a0,
      b1: b1 / a0,
      b2: b2 / a0,
      a1: a1 / a0,
      a2: a2 / a0,
    );
  }

  double process(double input) {
    final c = _coefficients;
    final output =
        c.b0 * input + c.b1 * _x1 + c.b2 * _x2 - c.a1 * _y1 - c.a2 * _y2;
    _x2 = _x1;
    _x1 = input;
    _y2 = _y1;
    _y1 = output;
    return output;
  }

  void reset() {
    _x1 = 0;
    _x2 = 0;
    _y1 = 0;
    _y2 = 0;
  }
}

class EqualizerDsp {
  EqualizerDsp({
    required this.sampleRate,
    required this.channels,
    EqualizerSettings? settings,
  }) : _settings = settings ?? EqualizerSettings.flat() {
    _rebuild();
  }

  final double sampleRate;
  final int channels;
  EqualizerSettings _settings;
  late List<List<BiquadFilter>> _filters;

  EqualizerSettings get settings => _settings;

  void setSettings(EqualizerSettings settings) {
    _settings = settings;
    _rebuild();
  }

  Float32List process(Float32List samples) {
    final output = Float32List.fromList(samples);
    for (var frame = 0; frame < output.length; frame++) {
      final channel = frame % channels;
      var value = output[frame];
      for (final filter in _filters[channel]) {
        value = filter.process(value);
      }
      output[frame] = value.clamp(-1.0, 1.0).toDouble();
    }
    return output;
  }

  void reset() {
    for (final channelFilters in _filters) {
      for (final filter in channelFilters) {
        filter.reset();
      }
    }
  }

  void _rebuild() {
    _filters = [
      for (var channel = 0; channel < math.max(1, channels); channel++)
        [
          for (final band in EqualizerBand.values)
            BiquadFilter()
              ..configure(
                type: BiquadType.peaking,
                frequencyHz: band.frequencyHz.toDouble(),
                gainDb: _settings.gainsDb[band] ?? 0,
                sampleRate: sampleRate,
              ),
          if (_settings.bassBoostEnabled && _settings.bassBoostDb != 0)
            (BiquadFilter()
              ..configure(
                type: BiquadType.lowShelf,
                frequencyHz: 120,
                gainDb: _settings.bassBoostDb,
                sampleRate: sampleRate,
                q: .707,
              )),
          if (_settings.trebleBoostEnabled && _settings.trebleBoostDb != 0)
            (BiquadFilter()
              ..configure(
                type: BiquadType.highShelf,
                frequencyHz: 8000,
                gainDb: _settings.trebleBoostDb,
                sampleRate: sampleRate,
                q: .707,
              )),
        ],
    ];
  }
}
