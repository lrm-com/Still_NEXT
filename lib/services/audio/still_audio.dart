import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ── Native opaque type ────────────────────────────────────────────────

final class _StillPlayer extends Opaque {}

// ── Playback status enum (mirrors C enum) ─────────────────────────────

enum StillPlaybackStatus { stopped, loading, playing, paused, seeking, endOfList }

StillPlaybackStatus _statusFromInt(int v) =>
    v >= 0 && v < StillPlaybackStatus.values.length
        ? StillPlaybackStatus.values[v]
        : StillPlaybackStatus.stopped;

enum StillLoopMode { off, all, one }

// ── Result types ──────────────────────────────────────────────────────

class StillPosition {
  const StillPosition(this.positionSec, this.durationSec);
  final double positionSec;
  final double durationSec;
  Duration get position => Duration(microseconds: (positionSec * 1e6).round());
  Duration get duration => Duration(microseconds: (durationSec * 1e6).round());
}

class StillSpectrumFrame {
  StillSpectrumFrame(Float32List m) : magnitudes = Float32List.fromList(m);
  final Float32List magnitudes;
}

// ── Native library loader ─────────────────────────────────────────────

DynamicLibrary? _openLibrary() {
  final names = Platform.isWindows
      ? ['still_audio.dll']
      : Platform.isMacOS
          ? ['libstill_audio.dylib']
          : ['libstill_audio.so'];
  for (final name in names) {
    try {
      return DynamicLibrary.open(name);
    } on Object {
      continue;
    }
  }
  return null;
}

// ── Global callback registry ──────────────────────────────────────────
// Native callbacks arrive on the audio thread; we dispatch to the
// correct StillPlayer instance via the userData pointer.

final Map<int, StillPlayer> _instances = {};

void _cbPosition(double pos, double dur, Pointer<Void> ud) {
  final p = _instances[ud.address];
  if (p != null && !p._disposed) {
    p._posCtrl.add(StillPosition(pos, dur));
  }
}

void _cbState(int status, int idx, Pointer<Void> ud) {
  print('[StillAudio] _cbState: status=$status idx=$idx ud=${ud.address}');
  final p = _instances[ud.address];
  if (p != null && !p._disposed) {
    p._stateCtrl.add(_statusFromInt(status));
  } else {
    print('[StillAudio] _cbState: instance not found or disposed');
  }
}

void _cbSpectrum(Pointer<Float> mag, int len, Pointer<Void> ud) {
  final p = _instances[ud.address];
  if (p != null && !p._disposed) {
    p._specCtrl.add(StillSpectrumFrame(mag.asTypedList(len)));
  }
}

// ── StillPlayer ───────────────────────────────────────────────────────

class StillPlayer {
  StillPlayer() : _lib = _openLibrary() {
    if (_lib == null) throw StateError('still_audio.dll not found');
    _h = _create();
    if (_h == nullptr) throw StateError('still_create() returned null');
    _id = _h.address;
    _instances[_id] = this;
    _bindCb();
  }

  final DynamicLibrary? _lib;
  late final Pointer<_StillPlayer> _h;
  late final int _id;
  bool _disposed = false;

  final _stateCtrl = StreamController<StillPlaybackStatus>.broadcast();
  final _posCtrl   = StreamController<StillPosition>.broadcast();
  final _specCtrl  = StreamController<StillSpectrumFrame>.broadcast();

  Stream<StillPlaybackStatus> get stateStream  => _stateCtrl.stream;
  Stream<StillPosition>       get positionStream => _posCtrl.stream;
  Stream<StillSpectrumFrame>  get spectrumStream => _specCtrl.stream;

  // Keep NativeCallable alive (prevent GC).
  final List<Object> _keepAlive = [];

  // ── FFI lookups ──────────────────────────────────────────────────

  late final Pointer<_StillPlayer> Function() _create =
      _lib!.lookupFunction<Pointer<_StillPlayer> Function(), Pointer<_StillPlayer> Function()>('still_create');

  late final void Function(Pointer<_StillPlayer>) _destroy =
      _lib!.lookupFunction<Void Function(Pointer<_StillPlayer>), void Function(Pointer<_StillPlayer>)>('still_destroy');

  late final int Function(Pointer<_StillPlayer>, Pointer<Pointer<Utf8>>, int) _setQueue =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Pointer<Pointer<Utf8>>, Int32), int Function(Pointer<_StillPlayer>, Pointer<Pointer<Utf8>>, int)>('still_set_queue');

  late final int Function(Pointer<_StillPlayer>) _play =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>), int Function(Pointer<_StillPlayer>)>('still_play');
  late final int Function(Pointer<_StillPlayer>) _pause =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>), int Function(Pointer<_StillPlayer>)>('still_pause');
  late final int Function(Pointer<_StillPlayer>) _stop =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>), int Function(Pointer<_StillPlayer>)>('still_stop');

  late final int Function(Pointer<_StillPlayer>, double) _seek =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Double), int Function(Pointer<_StillPlayer>, double)>('still_seek');
  late final int Function(Pointer<_StillPlayer>, int) _seekToTrack =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Int32), int Function(Pointer<_StillPlayer>, int)>('still_seek_to_track');

  late final int Function(Pointer<_StillPlayer>, double) _setVolume =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Float), int Function(Pointer<_StillPlayer>, double)>('still_set_volume');
  late final int Function(Pointer<_StillPlayer>, double) _setSpeed =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Float), int Function(Pointer<_StillPlayer>, double)>('still_set_speed');
  late final int Function(Pointer<_StillPlayer>, int) _setLoopMode =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Int32), int Function(Pointer<_StillPlayer>, int)>('still_set_loop_mode');
  late final int Function(Pointer<_StillPlayer>, bool) _setMuted =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Bool), int Function(Pointer<_StillPlayer>, bool)>('still_set_muted');

  late final double Function(Pointer<_StillPlayer>) _getVolume =
      _lib!.lookupFunction<Float Function(Pointer<_StillPlayer>), double Function(Pointer<_StillPlayer>)>('still_get_volume');
  late final double Function(Pointer<_StillPlayer>) _getSpeed =
      _lib!.lookupFunction<Float Function(Pointer<_StillPlayer>), double Function(Pointer<_StillPlayer>)>('still_get_speed');
  late final double Function(Pointer<_StillPlayer>) _getPosition =
      _lib!.lookupFunction<Double Function(Pointer<_StillPlayer>), double Function(Pointer<_StillPlayer>)>('still_get_position');
  late final double Function(Pointer<_StillPlayer>) _getDuration =
      _lib!.lookupFunction<Double Function(Pointer<_StillPlayer>), double Function(Pointer<_StillPlayer>)>('still_get_duration');
  late final int Function(Pointer<_StillPlayer>) _getStatus =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>), int Function(Pointer<_StillPlayer>)>('still_get_status');
  late final int Function(Pointer<_StillPlayer>) _getCurrentIndex =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>), int Function(Pointer<_StillPlayer>)>('still_get_current_index');
  late final int Function(Pointer<_StillPlayer>) _getQueueLen =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>), int Function(Pointer<_StillPlayer>)>('still_get_queue_length');

  late final int Function(Pointer<_StillPlayer>, Pointer<Float>, int) _setEqBands =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Pointer<Float>, Int32), int Function(Pointer<_StillPlayer>, Pointer<Float>, int)>('still_set_equalizer_bands');
  late final int Function(Pointer<_StillPlayer>, bool, double) _setBassBoost =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Bool, Float), int Function(Pointer<_StillPlayer>, bool, double)>('still_set_bass_boost');
  late final int Function(Pointer<_StillPlayer>, bool, double) _setTrebleBoost =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Bool, Float), int Function(Pointer<_StillPlayer>, bool, double)>('still_set_treble_boost');
  late final int Function(Pointer<_StillPlayer>, double) _setReplayGain =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Float), int Function(Pointer<_StillPlayer>, double)>('still_set_replay_gain');
  late final int Function(Pointer<_StillPlayer>, double) _fadeIn =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Float), int Function(Pointer<_StillPlayer>, double)>('still_fade_in');
  late final int Function(Pointer<_StillPlayer>, double) _fadeOut =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Float), int Function(Pointer<_StillPlayer>, double)>('still_fade_out');
  late final int Function(Pointer<_StillPlayer>, int) _setFftSize =
      _lib!.lookupFunction<Int32 Function(Pointer<_StillPlayer>, Int32), int Function(Pointer<_StillPlayer>, int)>('still_set_fft_size');
  late final Pointer<Utf8> Function(Pointer<_StillPlayer>) _lastError =
      _lib!.lookupFunction<Pointer<Utf8> Function(Pointer<_StillPlayer>), Pointer<Utf8> Function(Pointer<_StillPlayer>)>('still_last_error');

  // ── Callback registration ────────────────────────────────────────

  void _bindCb() {
    final cbPos  = NativeCallable<Void Function(Double, Double, Pointer<Void>)>.listener(_cbPosition);
    final cbState = NativeCallable<Void Function(Int32, Int32, Pointer<Void>)>.listener(_cbState);
    final cbSpec = NativeCallable<Void Function(Pointer<Float>, Int32, Pointer<Void>)>.listener(_cbSpectrum);
    _keepAlive.addAll([cbPos, cbState, cbSpec]);

    // Lookup the set-callback functions using generic Pointer types
    final setPosFn = _lib!.lookupFunction<
        Void Function(Pointer<_StillPlayer>, Pointer, Pointer),
        void Function(Pointer<_StillPlayer>, Pointer, Pointer)>('still_set_position_callback');
    final setStateFn = _lib!.lookupFunction<
        Void Function(Pointer<_StillPlayer>, Pointer, Pointer),
        void Function(Pointer<_StillPlayer>, Pointer, Pointer)>('still_set_state_callback');
    final setSpecFn = _lib!.lookupFunction<
        Void Function(Pointer<_StillPlayer>, Pointer, Pointer),
        void Function(Pointer<_StillPlayer>, Pointer, Pointer)>('still_set_spectrum_callback');

    final ud = Pointer.fromAddress(_id);
    setPosFn(_h, cbPos.nativeFunction, ud);
    setStateFn(_h, cbState.nativeFunction, ud);
    setSpecFn(_h, cbSpec.nativeFunction, ud);
  }

  // ── Public API ───────────────────────────────────────────────────

  int setQueue(List<String> paths) {
    _check();
    final ptr = calloc<Pointer<Utf8>>(paths.length);
    for (var i = 0; i < paths.length; i++) {
      ptr[i] = paths[i].toNativeUtf8();
    }
    final r = _setQueue(_h, ptr, paths.length);
    for (var i = 0; i < paths.length; i++) calloc.free(ptr[i]);
    calloc.free(ptr);
    return r;
  }

  int get currentIndex => _getCurrentIndex(_h);
  int get queueLength  => _getQueueLen(_h);

  int play()  { _check(); print('[StillAudio] play() called'); final r = _play(_h); print('[StillAudio] play() returned $r, lastError: $lastError'); return r; }
  int pause() { _check(); return _pause(_h); }
  int stop()  { _check(); return _stop(_h); }

  int seek(Duration pos)          { _check(); return _seek(_h, pos.inMicroseconds / 1e6); }
  int seekToTrack(int idx)        { _check(); return _seekToTrack(_h, idx); }
  int setVolume(double v)         { _check(); return _setVolume(_h, v); }
  int setSpeed(double s)          { _check(); return _setSpeed(_h, s); }
  int setMuted(bool m)            { _check(); return _setMuted(_h, m); }
  int setLoopMode(StillLoopMode m){ _check(); return _setLoopMode(_h, m.index); }

  double get volume   => _getVolume(_h);
  double get speed    => _getSpeed(_h);
  double get position => _getPosition(_h);
  double get duration => _getDuration(_h);
  StillPlaybackStatus get status => _statusFromInt(_getStatus(_h));

  int setEqualizerBands(List<double> gains) {
    _check();
    final ptr = calloc<Float>(gains.length);
    for (var i = 0; i < gains.length; i++) ptr[i] = gains[i];
    final r = _setEqBands(_h, ptr, gains.length);
    calloc.free(ptr);
    return r;
  }

  int setBassBoost(bool on, double dB)    { _check(); return _setBassBoost(_h, on, dB); }
  int setTrebleBoost(bool on, double dB)  { _check(); return _setTrebleBoost(_h, on, dB); }
  int setReplayGain(double dB)            { _check(); return _setReplayGain(_h, dB); }
  int fadeIn(Duration d)                  { _check(); return _fadeIn(_h, d.inMicroseconds / 1e6); }
  int fadeOut(Duration d)                 { _check(); return _fadeOut(_h, d.inMicroseconds / 1e6); }
  int setFftSize(int n)                  { _check(); return _setFftSize(_h, n); }

  String get lastError => _lastError(_h).toDartString();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _instances.remove(_id);
    _destroy(_h);
    _stateCtrl.close();
    _posCtrl.close();
    _specCtrl.close();
  }

  void _check() {
    if (_disposed) throw StateError('StillPlayer disposed');
  }
}
