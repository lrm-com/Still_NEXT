enum EqualizerBand {
  hz31(31),
  hz62(62),
  hz125(125),
  hz250(250),
  hz500(500),
  hz1k(1000),
  hz2k(2000),
  hz4k(4000),
  hz8k(8000),
  hz16k(16000);

  const EqualizerBand(this.frequencyHz);

  final int frequencyHz;
}

class EqualizerSettings {
  EqualizerSettings({
    Map<EqualizerBand, double>? gainsDb,
    this.bassBoostEnabled = false,
    this.trebleBoostEnabled = false,
    this.bassBoostDb = 0,
    this.trebleBoostDb = 0,
  }) : gainsDb = _normalize(gainsDb ?? const {}) {
    _validateGain(bassBoostDb, 'bassBoostDb');
    _validateGain(trebleBoostDb, 'trebleBoostDb');
  }

  final Map<EqualizerBand, double> gainsDb;
  final bool bassBoostEnabled;
  final bool trebleBoostEnabled;
  final double bassBoostDb;
  final double trebleBoostDb;

  factory EqualizerSettings.flat() => EqualizerSettings();

  EqualizerSettings copyWith({
    Map<EqualizerBand, double>? gainsDb,
    bool? bassBoostEnabled,
    bool? trebleBoostEnabled,
    double? bassBoostDb,
    double? trebleBoostDb,
  }) {
    return EqualizerSettings(
      gainsDb: gainsDb ?? this.gainsDb,
      bassBoostEnabled: bassBoostEnabled ?? this.bassBoostEnabled,
      trebleBoostEnabled: trebleBoostEnabled ?? this.trebleBoostEnabled,
      bassBoostDb: bassBoostDb ?? this.bassBoostDb,
      trebleBoostDb: trebleBoostDb ?? this.trebleBoostDb,
    );
  }

  static Map<EqualizerBand, double> _normalize(
    Map<EqualizerBand, double> input,
  ) {
    return Map.unmodifiable({
      for (final band in EqualizerBand.values)
        band: _validateGain(input[band] ?? 0, band.name),
    });
  }

  static double _validateGain(double value, String name) {
    if (value < -12 || value > 12) {
      throw RangeError.range(value, -12, 12, name);
    }
    return value;
  }
}

enum EqualizerPreset { flat, rock, pop, jazz, classical, dance, vocal, custom }

class EqualizerPresets {
  const EqualizerPresets._();

  static EqualizerSettings forPreset(EqualizerPreset preset) {
    const presets = <EqualizerPreset, List<double>>{
      EqualizerPreset.flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      EqualizerPreset.rock: [5, 4, 3, 1, -1, -1, 2, 3, 4, 5],
      EqualizerPreset.pop: [-1, 2, 4, 4, 2, 0, -1, -1, 2, 3],
      EqualizerPreset.jazz: [3, 2, 1, 2, -2, -2, 0, 1, 3, 4],
      EqualizerPreset.classical: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],
      EqualizerPreset.dance: [5, 4, 1, 0, -2, 2, 1, 2, 4, 3],
      EqualizerPreset.vocal: [-2, -1, 1, 3, 4, 4, 3, 1, 0, -1],
    };
    final values = presets[preset] ?? presets[EqualizerPreset.flat]!;
    return EqualizerSettings(
      gainsDb: {
        for (var index = 0; index < EqualizerBand.values.length; index++)
          EqualizerBand.values[index]: values[index],
      },
    );
  }
}
