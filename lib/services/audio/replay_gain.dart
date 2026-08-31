import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_track.dart';

enum ReplayGainMode { off, track, album }

class ReplayGainSettings {
  const ReplayGainSettings({
    this.mode = ReplayGainMode.off,
    this.preampDb = 0,
    this.preventClipping = true,
  }) : assert(preampDb >= -12 && preampDb <= 12);

  final ReplayGainMode mode;
  final double preampDb;
  final bool preventClipping;
}

class ReplayGainCalculator {
  const ReplayGainCalculator();

  double gainFor(AudioTrack track, ReplayGainSettings settings) {
    if (settings.mode == ReplayGainMode.off) return 0;

    final gain = settings.mode == ReplayGainMode.track
        ? track.trackGainDb
        : track.albumGainDb;
    final peak = settings.mode == ReplayGainMode.track
        ? track.trackPeak
        : track.albumPeak;
    var result = (gain ?? 0) + settings.preampDb;

    if (settings.preventClipping && peak != null && peak > 0) {
      final maximumGain = -20 * (math.log(peak) / math.ln10);
      result = math.min(result, maximumGain);
    }
    return result;
  }
}

enum ReplayGainScanMode { ebuR128, classic }

class ReplayGainScanResult {
  const ReplayGainScanResult({
    required this.trackGainDb,
    required this.trackPeak,
    this.albumGainDb,
    this.albumPeak,
    this.loudnessLufs,
    this.sampleRate,
    this.channels,
  });

  final double trackGainDb;
  final double trackPeak;
  final double? albumGainDb;
  final double? albumPeak;
  final double? loudnessLufs;
  final int? sampleRate;
  final int? channels;
}

/// Deterministic PCM ReplayGain scanner. WAV is decoded in-process; other
/// formats can be supplied through [scanPcm] after a decoder has produced PCM.
class ReplayGainScanner {
  const ReplayGainScanner({this.targetLufs = -18});

  final double targetLufs;

  ReplayGainScanResult scanPcm(
    Float32List samples, {
    required int sampleRate,
    required int channels,
    ReplayGainScanMode mode = ReplayGainScanMode.ebuR128,
  }) {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'must not be empty');
    }
    var sumSquares = 0.0;
    var peak = 0.0;
    for (final sample in samples) {
      final absolute = sample.abs();
      if (absolute > peak) peak = absolute;
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    final loudness = mode == ReplayGainScanMode.ebuR128
        ? -0.691 + 20 * math.log(rms + 1e-12) / math.ln10
        : 20 * math.log(rms + 1e-12) / math.ln10;
    return ReplayGainScanResult(
      trackGainDb: targetLufs - loudness,
      trackPeak: peak,
      loudnessLufs: loudness,
      sampleRate: sampleRate,
      channels: channels,
    );
  }

  Future<ReplayGainScanResult> scanFile(
    String path, {
    ReplayGainScanMode mode = ReplayGainScanMode.ebuR128,
  }) async {
    final pcm = await _WavReader.read(path);
    return scanPcm(
      pcm.samples,
      sampleRate: pcm.sampleRate,
      channels: pcm.channels,
      mode: mode,
    );
  }

  Future<List<ReplayGainScanResult>> scanFiles(
    Iterable<String> paths, {
    ReplayGainScanMode mode = ReplayGainScanMode.ebuR128,
    void Function(int completed, int total)? onProgress,
  }) async {
    final items = paths.toList(growable: false);
    final results = <ReplayGainScanResult>[];
    for (var index = 0; index < items.length; index++) {
      results.add(await scanFile(items[index], mode: mode));
      onProgress?.call(index + 1, items.length);
    }
    if (results.isEmpty) return results;
    var albumPeak = 0.0;
    for (final result in results) {
      if (result.trackPeak > albumPeak) albumPeak = result.trackPeak;
    }
    final albumGain =
        results.map((result) => result.trackGainDb).reduce((a, b) => a + b) /
            results.length;
    return [
      for (final result in results)
        ReplayGainScanResult(
          trackGainDb: result.trackGainDb,
          trackPeak: result.trackPeak,
          albumGainDb: albumGain,
          albumPeak: albumPeak,
          loudnessLufs: result.loudnessLufs,
          sampleRate: result.sampleRate,
          channels: result.channels,
        ),
    ];
  }
}

class AudioTags {
  const AudioTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.year,
    this.genre,
    this.trackNumber,
    this.discNumber,
    this.comment,
    this.lyrics,
    this.cover,
    this.trackGainDb,
    this.trackPeak,
    this.albumGainDb,
    this.albumPeak,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? year;
  final String? genre;
  final int? trackNumber;
  final int? discNumber;
  final String? comment;
  final String? lyrics;
  final Uint8List? cover;
  final double? trackGainDb;
  final double? trackPeak;
  final double? albumGainDb;
  final double? albumPeak;

  AudioTags copyWith({
    Object? title = _unset,
    Object? artist = _unset,
    Object? album = _unset,
    Object? albumArtist = _unset,
    Object? year = _unset,
    Object? genre = _unset,
    Object? trackNumber = _unset,
    Object? discNumber = _unset,
    Object? comment = _unset,
    Object? lyrics = _unset,
    Object? cover = _unset,
    Object? trackGainDb = _unset,
    Object? trackPeak = _unset,
    Object? albumGainDb = _unset,
    Object? albumPeak = _unset,
  }) {
    return AudioTags(
      title: identical(title, _unset) ? this.title : title as String?,
      artist: identical(artist, _unset) ? this.artist : artist as String?,
      album: identical(album, _unset) ? this.album : album as String?,
      albumArtist: identical(albumArtist, _unset)
          ? this.albumArtist
          : albumArtist as String?,
      year: identical(year, _unset) ? this.year : year as int?,
      genre: identical(genre, _unset) ? this.genre : genre as String?,
      trackNumber: identical(trackNumber, _unset)
          ? this.trackNumber
          : trackNumber as int?,
      discNumber:
          identical(discNumber, _unset) ? this.discNumber : discNumber as int?,
      comment: identical(comment, _unset) ? this.comment : comment as String?,
      lyrics: identical(lyrics, _unset) ? this.lyrics : lyrics as String?,
      cover: identical(cover, _unset) ? this.cover : cover as Uint8List?,
      trackGainDb: identical(trackGainDb, _unset)
          ? this.trackGainDb
          : trackGainDb as double?,
      trackPeak:
          identical(trackPeak, _unset) ? this.trackPeak : trackPeak as double?,
      albumGainDb: identical(albumGainDb, _unset)
          ? this.albumGainDb
          : albumGainDb as double?,
      albumPeak:
          identical(albumPeak, _unset) ? this.albumPeak : albumPeak as double?,
    );
  }

  static const _unset = Object();
}

class AudioTagEditor {
  const AudioTagEditor();

  Future<AudioTags> read(String path) async {
    final bytes = await File(path).readAsBytes();
    final extension = path.toLowerCase().split('.').last;
    if (extension == 'mp3') return _Id3Codec.read(bytes);
    if (extension == 'flac') return _FlacCodec.read(bytes);
    throw UnsupportedError('Tag editing is not supported for .$extension');
  }

  Future<void> write(String path, AudioTags tags) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final extension = path.toLowerCase().split('.').last;
    if (extension == 'mp3') {
      await file.writeAsBytes(_Id3Codec.write(bytes, tags), flush: true);
      return;
    }
    if (extension == 'flac') {
      await file.writeAsBytes(_FlacCodec.write(bytes, tags), flush: true);
      return;
    }
    throw UnsupportedError('Tag editing is not supported for .$extension');
  }
}

class BatchTagEditor {
  const BatchTagEditor({AudioTagEditor? editor})
      : _editor = editor ?? const AudioTagEditor();

  final AudioTagEditor _editor;

  Future<void> update(
    Iterable<String> paths,
    AudioTags Function(String path, AudioTags current) transform, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final items = paths.toList(growable: false);
    for (var index = 0; index < items.length; index++) {
      final current = await _editor.read(items[index]);
      await _editor.write(items[index], transform(items[index], current));
      onProgress?.call(index + 1, items.length);
    }
  }
}

enum TranscodeFormat { mp3, flac, ogg, opus, aac }

class TranscodeOptions {
  const TranscodeOptions({
    required this.inputPath,
    required this.outputPath,
    required this.format,
    this.quality,
    this.bitrateKbps,
    this.ffmpegExecutable = 'ffmpeg',
    this.overwrite = false,
  });

  final String inputPath;
  final String outputPath;
  final TranscodeFormat format;
  final int? quality;
  final int? bitrateKbps;
  final String ffmpegExecutable;
  final bool overwrite;
}

class TranscodeResult {
  const TranscodeResult(
      {required this.exitCode, required this.outputPath, required this.stderr});

  final int exitCode;
  final String outputPath;
  final String stderr;
}

class FfmpegTranscoder {
  const FfmpegTranscoder();

  Future<TranscodeResult> transcode(
    TranscodeOptions options, {
    Duration? duration,
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    final arguments = buildArguments(options, duration: duration);
    final process = await Process.start(options.ffmpegExecutable, arguments);
    final stderr = StringBuffer();
    var cancelled = false;
    cancel?.then((_) {
      cancelled = true;
      process.kill(ProcessSignal.sigterm);
    });
    await for (final line in process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      stderr.writeln(line);
      final timestamp =
          RegExp(r'time=(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(line);
      if (timestamp != null &&
          duration != null &&
          duration.inMicroseconds > 0) {
        final seconds = int.parse(timestamp.group(1)!) * 3600 +
            int.parse(timestamp.group(2)!) * 60 +
            double.parse(timestamp.group(3)!);
        onProgress?.call((seconds / duration.inMicroseconds * 1000000)
            .clamp(0, 1)
            .toDouble());
      }
    }
    final exitCode = await process.exitCode;
    if (cancelled) throw StateError('Transcoding was cancelled');
    if (exitCode != 0)
      throw ProcessException(
          options.ffmpegExecutable, arguments, stderr.toString(), exitCode);
    onProgress?.call(1);
    return TranscodeResult(
        exitCode: exitCode,
        outputPath: options.outputPath,
        stderr: stderr.toString());
  }

  List<String> buildArguments(TranscodeOptions options, {Duration? duration}) {
    final arguments = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      if (options.overwrite) '-y' else '-n',
      '-i',
      options.inputPath
    ];
    switch (options.format) {
      case TranscodeFormat.mp3:
        arguments.addAll(['-c:a', 'libmp3lame']);
      case TranscodeFormat.flac:
        arguments.addAll(['-c:a', 'flac']);
      case TranscodeFormat.ogg:
        arguments.addAll(['-c:a', 'libvorbis']);
      case TranscodeFormat.opus:
        arguments.addAll(['-c:a', 'libopus']);
      case TranscodeFormat.aac:
        arguments.addAll(['-c:a', 'aac']);
    }
    if (options.bitrateKbps != null)
      arguments.addAll(['-b:a', '${options.bitrateKbps}k']);
    if (options.quality != null)
      arguments.addAll(['-q:a', '${options.quality}']);
    arguments.addAll(['-progress', 'pipe:2', options.outputPath]);
    return arguments;
  }
}

class _WavData {
  const _WavData(this.samples, this.sampleRate, this.channels);
  final Float32List samples;
  final int sampleRate;
  final int channels;
}

class _WavReader {
  static Future<_WavData> read(String path) async =>
      _parse(await File(path).readAsBytes());

  static _WavData _parse(Uint8List bytes) {
    if (bytes.length < 44 ||
        ascii.decode(bytes.sublist(0, 4)) != 'RIFF' ||
        ascii.decode(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException(
          'Only RIFF/WAVE PCM files can be scanned directly');
    }
    var format = 1;
    var channels = 0;
    var sampleRate = 0;
    var bits = 0;
    var offset = 12;
    var dataStart = -1;
    var dataLength = 0;
    while (offset + 8 <= bytes.length) {
      final id = ascii.decode(bytes.sublist(offset, offset + 4));
      final length = _u32(bytes, offset + 4);
      final end = math.min(bytes.length, offset + 8 + length);
      if (id == 'fmt ' && end >= offset + 24) {
        format = _u16(bytes, offset + 8);
        channels = _u16(bytes, offset + 10);
        sampleRate = _u32(bytes, offset + 12);
        bits = _u16(bytes, offset + 22);
      } else if (id == 'data') {
        dataStart = offset + 8;
        dataLength = math.min(length, bytes.length - dataStart);
        break;
      }
      offset = end + (length.isOdd ? 1 : 0);
    }
    if (format != 1 && format != 3 ||
        channels < 1 ||
        sampleRate < 1 ||
        dataStart < 0) {
      throw const FormatException('Unsupported WAV format');
    }
    final bytesPerSample = (bits / 8).ceil();
    final count = dataLength ~/ bytesPerSample;
    final samples = Float32List(count);
    for (var index = 0; index < count; index++) {
      final start = dataStart + index * bytesPerSample;
      samples[index] = switch (bits) {
        8 => (bytes[start] - 128) / 128,
        16 => _signed16(bytes, start) / 32768,
        24 => _signed24(bytes, start) / 8388608,
        32 when format == 3 => ByteData.sublistView(bytes, start, start + 4)
            .getFloat32(0, Endian.little),
        32 => _signed32(bytes, start) / 2147483648,
        _ => throw FormatException('Unsupported WAV bit depth: $bits'),
      };
    }
    return _WavData(samples, sampleRate, channels);
  }

  static int _u16(Uint8List bytes, int offset) =>
      bytes[offset] | bytes[offset + 1] << 8;
  static int _u32(Uint8List bytes, int offset) =>
      bytes[offset] |
      bytes[offset + 1] << 8 |
      bytes[offset + 2] << 16 |
      bytes[offset + 3] << 24;
  static int _signed16(Uint8List b, int o) =>
      _u16(b, o) < 0x8000 ? _u16(b, o) : _u16(b, o) - 0x10000;
  static int _signed24(Uint8List b, int o) {
    final value = b[o] | b[o + 1] << 8 | b[o + 2] << 16;
    return value < 0x800000 ? value : value - 0x1000000;
  }

  static int _signed32(Uint8List b, int o) {
    final value = _u32(b, o);
    return value < 0x80000000 ? value : value - 0x100000000;
  }
}

class _Id3Codec {
  static AudioTags read(Uint8List bytes) {
    if (bytes.length < 10 || ascii.decode(bytes.sublist(0, 3)) != 'ID3')
      return const AudioTags();
    final size = _synchsafe(bytes, 6);
    final end = math.min(bytes.length, 10 + size);
    var offset = 10;
    var tags = const AudioTags();
    while (offset + 10 <= end) {
      final id = ascii.decode(bytes.sublist(offset, offset + 4));
      final length = _u32(bytes, offset + 4);
      if (id.trim().isEmpty || length <= 0 || offset + 10 + length > end) break;
      final body = bytes.sublist(offset + 10, offset + 10 + length);
      final text = _decodeText(body);
      tags = switch (id) {
        'TIT2' => tags.copyWith(title: text),
        'TPE1' => tags.copyWith(artist: text),
        'TALB' => tags.copyWith(album: text),
        'TPE2' => tags.copyWith(albumArtist: text),
        'TDRC' || 'TYER' => tags.copyWith(year: int.tryParse(text)),
        'TCON' => tags.copyWith(genre: text),
        'TRCK' =>
          tags.copyWith(trackNumber: int.tryParse(text.split('/').first)),
        'TPOS' =>
          tags.copyWith(discNumber: int.tryParse(text.split('/').first)),
        'COMM' => tags.copyWith(comment: _decodeComment(body)),
        'USLT' => tags.copyWith(lyrics: _decodeLyrics(body)),
        'TXXX' => _applyUserText(tags, body),
        _ => tags,
      };
      offset += 10 + length;
    }
    return tags;
  }

  static Uint8List write(Uint8List original, AudioTags tags) {
    var audioOffset = 0;
    if (original.length >= 10 && ascii.decode(original.sublist(0, 3)) == 'ID3')
      audioOffset = 10 + _synchsafe(original, 6);
    final frames = <Uint8List>[];
    void addText(String id, String? value) {
      if (value == null) return;
      frames.add(_frame(id, Uint8List.fromList([3, ...utf8.encode(value)])));
    }

    addText('TIT2', tags.title);
    addText('TPE1', tags.artist);
    addText('TALB', tags.album);
    addText('TPE2', tags.albumArtist);
    addText('TDRC', tags.year?.toString());
    addText('TCON', tags.genre);
    addText('TRCK', tags.trackNumber?.toString());
    addText('TPOS', tags.discNumber?.toString());
    addText(
        'COMM',
        tags.comment == null
            ? null
            : String.fromCharCodes(
                [3, 0, 0, 0, ...utf8.encode(tags.comment!)]));
    _addUserText(
        frames,
        'replaygain_track_gain',
        tags.trackGainDb == null
            ? null
            : '${tags.trackGainDb!.toStringAsFixed(2)} dB');
    _addUserText(frames, 'replaygain_track_peak', tags.trackPeak?.toString());
    _addUserText(
        frames,
        'replaygain_album_gain',
        tags.albumGainDb == null
            ? null
            : '${tags.albumGainDb!.toStringAsFixed(2)} dB');
    _addUserText(frames, 'replaygain_album_peak', tags.albumPeak?.toString());
    final body = Uint8List.fromList(frames.expand((frame) => frame).toList());
    final header = Uint8List.fromList([
      ascii.encode('ID3')[0],
      ascii.encode('ID3')[1],
      ascii.encode('ID3')[2],
      4,
      0,
      0,
      ..._synchsafeBytes(body.length)
    ]);
    return Uint8List.fromList(
        [...header, ...body, ...original.sublist(audioOffset)]);
  }

  static String _decodeText(List<int> body) {
    if (body.length < 2) return '';
    final encoding = body.first;
    final data = body.sublist(1);
    return encoding == 3
        ? utf8.decode(data, allowMalformed: true).split('\u0000').first
        : latin1.decode(data).split('\u0000').first;
  }

  static String _decodeComment(List<int> body) => body.length < 5
      ? ''
      : (body[0] == 3
              ? utf8.decode(body.sublist(4), allowMalformed: true)
              : latin1.decode(body.sublist(4)))
          .split('\u0000')
          .last;

  static String? _decodeLyrics(List<int> body) {
    if (body.length < 5) return null;
    final encoding = body[0];
    // Skip encoding(1) + language(3) + content descriptor
    var offset = 4;
    // Skip null-terminated content descriptor (2-byte null for UTF-16)
    if (encoding == 1 || encoding == 2) {
      while (offset + 1 < body.length && !(body[offset] == 0 && body[offset + 1] == 0)) {
        offset += 2;
      }
      offset += 2; // skip the 2-byte null terminator
    } else {
      while (offset < body.length && body[offset] != 0) {
        offset++;
      }
      offset++; // skip the null terminator
    }
    if (offset >= body.length) return null;
    final data = body.sublist(offset);
    String text;
    if (encoding == 3) {
      text = utf8.decode(data, allowMalformed: true);
    } else if (encoding == 1) {
      // UTF-16 with BOM
      text = String.fromCharCodes(data);
    } else if (encoding == 2) {
      text = String.fromCharCodes(data);
    } else {
      text = latin1.decode(data);
    }
    return text.trim().isEmpty ? null : text.trim();
  }
  static AudioTags _applyUserText(AudioTags tags, List<int> body) {
    final value = _decodeText(body);
    final separator = value.indexOf('\u0000');
    if (separator < 0) return tags;
    final key = value.substring(0, separator).toLowerCase();
    final data = value.substring(separator + 1).replaceAll(' dB', '');
    return switch (key) {
      'replaygain_track_gain' =>
        tags.copyWith(trackGainDb: double.tryParse(data)),
      'replaygain_track_peak' =>
        tags.copyWith(trackPeak: double.tryParse(data)),
      'replaygain_album_gain' =>
        tags.copyWith(albumGainDb: double.tryParse(data)),
      'replaygain_album_peak' =>
        tags.copyWith(albumPeak: double.tryParse(data)),
      _ => tags
    };
  }

  static void _addUserText(List<Uint8List> frames, String key, String? value) {
    if (value != null)
      frames.add(_frame(
          'TXXX', Uint8List.fromList([3, ...utf8.encode('$key\u0000$value')])));
  }

  static Uint8List _frame(String id, Uint8List body) => Uint8List.fromList(
      [...ascii.encode(id), ..._u32Bytes(body.length), 0, 0, ...body]);
  static int _synchsafe(List<int> b, int o) =>
      b[o] << 21 | b[o + 1] << 14 | b[o + 2] << 7 | b[o + 3];
  static List<int> _synchsafeBytes(int value) => [
        (value >> 21) & 0x7f,
        (value >> 14) & 0x7f,
        (value >> 7) & 0x7f,
        value & 0x7f
      ];
  static List<int> _u32Bytes(int value) => [
        (value >> 24) & 255,
        (value >> 16) & 255,
        (value >> 8) & 255,
        value & 255
      ];
  static int _u32(List<int> b, int o) =>
      b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];
}

class _FlacCodec {
  static AudioTags read(Uint8List bytes) {
    if (bytes.length < 8 || ascii.decode(bytes.sublist(0, 4)) != 'fLaC')
      throw const FormatException('Invalid FLAC file');
    var offset = 4;
    var tags = const AudioTags();
    while (offset + 4 <= bytes.length) {
      final header = bytes[offset];
      final length =
          bytes[offset + 1] << 16 | bytes[offset + 2] << 8 | bytes[offset + 3];
      if ((header & 0x7f) == 4)
        tags = _readComments(
            bytes.sublist(
                offset + 4, math.min(bytes.length, offset + 4 + length)),
            tags);
      offset += 4 + length;
      if ((header & 0x80) != 0) break;
    }
    return tags;
  }

  static Uint8List write(Uint8List original, AudioTags tags) {
    if (original.length < 8 || ascii.decode(original.sublist(0, 4)) != 'fLaC')
      throw const FormatException('Invalid FLAC file');
    var offset = 4;
    final blocks = <List<int>>[];
    var replaced = false;
    while (offset + 4 <= original.length) {
      final header = original[offset];
      final length = original[offset + 1] << 16 |
          original[offset + 2] << 8 |
          original[offset + 3];
      final end = math.min(original.length, offset + 4 + length);
      if ((header & 0x7f) == 4) {
        blocks.add(_commentBlockBody(tags));
        replaced = true;
      } else
        blocks.add(original.sublist(offset + 4, end));
      offset = end;
      if ((header & 0x80) != 0) break;
    }
    if (!replaced) blocks.add(_commentBlockBody(tags));
    final encoded = <int>[...ascii.encode('fLaC')];
    for (var index = 0; index < blocks.length; index++) {
      final body = blocks[index];
      final type = index == blocks.length - 1
          ? 0x80
          : (index < blocks.length
              ? _blockType(original, index, blocks.length, body)
              : 4);
      encoded.addAll([
        type,
        (body.length >> 16) & 255,
        (body.length >> 8) & 255,
        body.length & 255,
        ...body
      ]);
    }
    encoded.addAll(original.sublist(offset));
    return Uint8List.fromList(encoded);
  }

  static int _blockType(
      Uint8List original, int index, int count, List<int> body) {
    var offset = 4;
    for (var current = 0;
        current <= index && offset + 4 <= original.length;
        current++) {
      final header = original[offset];
      final length = original[offset + 1] << 16 |
          original[offset + 2] << 8 |
          original[offset + 3];
      if (current == index) return header & 0x7f;
      offset += 4 + length;
    }
    return 4;
  }

  static AudioTags _readComments(List<int> block, AudioTags tags) {
    if (block.length < 8) return tags;
    var offset = 4;
    final count = block[4] | block[5] << 8 | block[6] << 16 | block[7] << 24;
    offset = 8;
    for (var index = 0; index < count && offset + 4 <= block.length; index++) {
      final length = block[offset] |
          block[offset + 1] << 8 |
          block[offset + 2] << 16 |
          block[offset + 3] << 24;
      offset += 4;
      final pair = utf8.decode(
          block.sublist(offset, math.min(block.length, offset + length)),
          allowMalformed: true);
      offset += length;
      final separator = pair.indexOf('=');
      if (separator < 0) continue;
      final key = pair.substring(0, separator).toLowerCase();
      final value = pair.substring(separator + 1);
      tags = _assign(tags, key, value);
    }
    return tags;
  }

  static AudioTags _assign(AudioTags tags, String key, String value) =>
      switch (key) {
        'title' => tags.copyWith(title: value),
        'artist' => tags.copyWith(artist: value),
        'album' => tags.copyWith(album: value),
        'albumartist' => tags.copyWith(albumArtist: value),
        'date' => tags.copyWith(year: int.tryParse(value)),
        'genre' => tags.copyWith(genre: value),
        'tracknumber' =>
          tags.copyWith(trackNumber: int.tryParse(value.split('/').first)),
        'discnumber' =>
          tags.copyWith(discNumber: int.tryParse(value.split('/').first)),
        'comment' => tags.copyWith(comment: value),
        'replaygain_track_gain' => tags.copyWith(
            trackGainDb: double.tryParse(value.replaceAll(' dB', ''))),
        'replaygain_track_peak' =>
          tags.copyWith(trackPeak: double.tryParse(value)),
        'replaygain_album_gain' => tags.copyWith(
            albumGainDb: double.tryParse(value.replaceAll(' dB', ''))),
        'replaygain_album_peak' =>
          tags.copyWith(albumPeak: double.tryParse(value)),
        'lyrics' => tags.copyWith(lyrics: value),
        _ => tags
      };
  static List<int> _commentBlockBody(AudioTags tags) {
    final values = <String>[
      'TITLE=${tags.title ?? ''}',
      'ARTIST=${tags.artist ?? ''}',
      'ALBUM=${tags.album ?? ''}',
      if (tags.albumArtist != null) 'ALBUMARTIST=${tags.albumArtist}',
      if (tags.year != null) 'DATE=${tags.year}',
      if (tags.genre != null) 'GENRE=${tags.genre}',
      if (tags.trackNumber != null) 'TRACKNUMBER=${tags.trackNumber}',
      if (tags.discNumber != null) 'DISCNUMBER=${tags.discNumber}',
      if (tags.comment != null) 'COMMENT=${tags.comment}',
      if (tags.lyrics != null) 'LYRICS=${tags.lyrics}',
      if (tags.trackGainDb != null)
        'REPLAYGAIN_TRACK_GAIN=${tags.trackGainDb} dB',
      if (tags.trackPeak != null) 'REPLAYGAIN_TRACK_PEAK=${tags.trackPeak}',
      if (tags.albumGainDb != null)
        'REPLAYGAIN_ALBUM_GAIN=${tags.albumGainDb} dB',
      if (tags.albumPeak != null) 'REPLAYGAIN_ALBUM_PEAK=${tags.albumPeak}'
    ];
    final vendor = utf8.encode('Still');
    return <int>[
      ..._le32(vendor.length),
      ...vendor,
      ..._le32(values.length),
      ...values.expand((value) =>
          [..._le32(utf8.encode(value).length), ...utf8.encode(value)])
    ];
  }

  static List<int> _le32(int value) => [
        value & 255,
        (value >> 8) & 255,
        (value >> 16) & 255,
        (value >> 24) & 255
      ];
}
