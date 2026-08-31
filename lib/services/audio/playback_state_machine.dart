import 'dart:math';

import 'playback_state.dart';

typedef ShuffleIndexGenerator = int Function(int upperBound);

final class PlaybackStateMachine<T> {
  PlaybackStateMachine({
    Iterable<T> queue = const [],
    int? currentIndex,
    PlaybackMode mode = PlaybackMode.sequential,
    PlaybackStatus status = PlaybackStatus.stopped,
    String? errorMessage,
    ShuffleIndexGenerator? shuffleIndexGenerator,
  }) : _shuffleIndexGenerator = shuffleIndexGenerator ?? Random().nextInt {
    final initialQueue = List<T>.of(queue);
    final initialIndex = initialQueue.isEmpty ? null : currentIndex ?? 0;
    _state = PlaybackState<T>(
      queue: initialQueue,
      currentIndex: initialIndex,
      mode: mode,
      status: initialQueue.isEmpty ? PlaybackStatus.stopped : status,
      errorMessage: initialQueue.isEmpty || status != PlaybackStatus.error
          ? null
          : errorMessage,
    );
    _resetShuffleHistory();
  }

  final ShuffleIndexGenerator _shuffleIndexGenerator;
  late PlaybackState<T> _state;
  final List<int> _shuffleHistory = <int>[];
  int _shuffleCursor = -1;

  PlaybackState<T> get state => _state;

  PlaybackState<T> setMode(PlaybackMode mode) {
    if (_state.mode == mode) {
      return _state;
    }
    _state = _state.copyWith(mode: mode);
    _resetShuffleHistory();
    return _state;
  }

  PlaybackState<T> cycleMode() {
    final modes = PlaybackMode.values;
    return setMode(modes[(_state.mode.index + 1) % modes.length]);
  }

  PlaybackState<T> play() {
    if (!_state.hasCurrentTrack) {
      return _state;
    }
    return _setStatus(PlaybackStatus.playing);
  }

  PlaybackState<T> pause() {
    if (_state.status != PlaybackStatus.playing &&
        _state.status != PlaybackStatus.loading) {
      return _state;
    }
    return _setStatus(PlaybackStatus.paused);
  }

  PlaybackState<T> stop() => _setStatus(PlaybackStatus.stopped);

  PlaybackState<T> markLoading({int? index}) {
    if (_state.isEmpty) {
      return stop();
    }
    if (index != null) {
      _checkIndex(index);
      _state = _state.copyWith(
        currentIndex: index,
        status: PlaybackStatus.loading,
      );
      _recordShuffleSelection(index);
      return _state;
    }
    return _setStatus(PlaybackStatus.loading);
  }

  PlaybackState<T> markPlaying() => play();

  PlaybackState<T> markPaused() => pause();

  PlaybackState<T> markCompleted() {
    if (!_state.hasCurrentTrack) {
      return _state;
    }
    return _setStatus(PlaybackStatus.completed);
  }

  PlaybackState<T> markError(Object error) {
    _state = _state.copyWith(
      status: PlaybackStatus.error,
      errorMessage: error.toString(),
    );
    return _state;
  }

  PlaybackState<T> select(int index) {
    _checkIndex(index);
    _state = _state.copyWith(
      currentIndex: index,
      status: PlaybackStatus.loading,
    );
    _recordShuffleSelection(index);
    return _state;
  }

  PlaybackState<T> next() => _navigate(forward: true);

  PlaybackState<T> previous() => _navigate(forward: false);

  PlaybackState<T> onTrackCompleted() {
    if (!_state.hasCurrentTrack) {
      return _state;
    }
    if (_state.mode == PlaybackMode.singleTrackLoop) {
      return markLoading();
    }
    return next();
  }

  PlaybackState<T> replaceQueue(Iterable<T> queue, {int? currentIndex}) {
    final nextQueue = List<T>.of(queue);
    if (nextQueue.isEmpty) {
      _state = PlaybackState<T>(mode: _state.mode);
      _resetShuffleHistory();
      return _state;
    }

    final nextIndex = currentIndex ?? 0;
    _checkIndexInQueue(nextIndex, nextQueue);
    _state = PlaybackState<T>(
      queue: nextQueue,
      currentIndex: nextIndex,
      mode: _state.mode,
      status: PlaybackStatus.stopped,
    );
    _resetShuffleHistory();
    return _state;
  }

  PlaybackState<T> add(T track) => addAll(<T>[track]);

  PlaybackState<T> addAll(Iterable<T> tracks) {
    final additions = List<T>.of(tracks);
    if (additions.isEmpty) {
      return _state;
    }
    final wasEmpty = _state.isEmpty;
    final nextQueue = <T>[..._state.queue, ...additions];
    _state = _state.copyWith(
      queue: nextQueue,
      currentIndex: wasEmpty ? 0 : _state.currentIndex,
      status: wasEmpty ? PlaybackStatus.stopped : _state.status,
    );
    if (wasEmpty) {
      _resetShuffleHistory();
    }
    return _state;
  }

  PlaybackState<T> insert(int index, T track) {
    if (index < 0 || index > _state.queue.length) {
      throw RangeError.range(index, 0, _state.queue.length, 'index');
    }
    final nextQueue = List<T>.of(_state.queue)..insert(index, track);
    final oldCurrentIndex = _state.currentIndex;
    final nextCurrentIndex = oldCurrentIndex == null
        ? 0
        : index <= oldCurrentIndex
            ? oldCurrentIndex + 1
            : oldCurrentIndex;
    _state = _state.copyWith(
      queue: nextQueue,
      currentIndex: nextCurrentIndex,
      status: oldCurrentIndex == null ? PlaybackStatus.stopped : _state.status,
    );
    _resetShuffleHistory();
    return _state;
  }

  PlaybackState<T> removeAt(int index) {
    _checkIndex(index);
    final nextQueue = List<T>.of(_state.queue)..removeAt(index);
    if (nextQueue.isEmpty) {
      _state = PlaybackState<T>(mode: _state.mode);
      _resetShuffleHistory();
      return _state;
    }

    final oldCurrentIndex = _state.currentIndex!;
    late final int nextCurrentIndex;
    late final PlaybackStatus nextStatus;
    if (index < oldCurrentIndex) {
      nextCurrentIndex = oldCurrentIndex - 1;
      nextStatus = _state.status;
    } else if (index > oldCurrentIndex) {
      nextCurrentIndex = oldCurrentIndex;
      nextStatus = _state.status;
    } else {
      nextCurrentIndex =
          index < nextQueue.length ? index : nextQueue.length - 1;
      nextStatus = _replacementStatus(_state.status);
    }

    _state = PlaybackState<T>(
      queue: nextQueue,
      currentIndex: nextCurrentIndex,
      mode: _state.mode,
      status: nextStatus,
    );
    _resetShuffleHistory();
    return _state;
  }

  PlaybackState<T> move(int fromIndex, int toIndex) {
    _checkIndex(fromIndex);
    _checkIndex(toIndex);
    if (fromIndex == toIndex) {
      return _state;
    }

    final nextQueue = List<T>.of(_state.queue);
    final track = nextQueue.removeAt(fromIndex);
    nextQueue.insert(toIndex, track);

    final oldCurrentIndex = _state.currentIndex!;
    late final int nextCurrentIndex;
    if (oldCurrentIndex == fromIndex) {
      nextCurrentIndex = toIndex;
    } else if (fromIndex < oldCurrentIndex && toIndex >= oldCurrentIndex) {
      nextCurrentIndex = oldCurrentIndex - 1;
    } else if (fromIndex > oldCurrentIndex && toIndex <= oldCurrentIndex) {
      nextCurrentIndex = oldCurrentIndex + 1;
    } else {
      nextCurrentIndex = oldCurrentIndex;
    }

    _state = _state.copyWith(queue: nextQueue, currentIndex: nextCurrentIndex);
    _resetShuffleHistory();
    return _state;
  }

  PlaybackState<T> clearQueue() {
    _state = PlaybackState<T>(mode: _state.mode);
    _resetShuffleHistory();
    return _state;
  }

  PlaybackState<T> _navigate({required bool forward}) {
    final currentIndex = _state.currentIndex;
    if (currentIndex == null) {
      return _state;
    }

    if (_state.mode == PlaybackMode.shuffle) {
      final target = forward ? _nextShuffleIndex() : _previousShuffleIndex();
      if (target == null) {
        return forward ? markCompleted() : _state;
      }
      return _loadIndex(target);
    }

    final delta = forward ? 1 : -1;
    var target = currentIndex + delta;
    if (_state.mode == PlaybackMode.playlistLoop) {
      target %= _state.queue.length;
    } else if (target < 0 || target >= _state.queue.length) {
      return forward ? markCompleted() : _state;
    }
    return _loadIndex(target);
  }

  PlaybackState<T> _loadIndex(int index) {
    _state = _state.copyWith(
      currentIndex: index,
      status: PlaybackStatus.loading,
    );
    return _state;
  }

  int? _nextShuffleIndex() {
    if (_shuffleCursor + 1 < _shuffleHistory.length) {
      _shuffleCursor++;
      return _shuffleHistory[_shuffleCursor];
    }

    final visited = _shuffleHistory.toSet();
    final candidates = <int>[
      for (var index = 0; index < _state.queue.length; index++)
        if (!visited.contains(index)) index,
    ];
    if (candidates.isEmpty) {
      return null;
    }

    final generatedIndex = _shuffleIndexGenerator(candidates.length);
    if (generatedIndex < 0 || generatedIndex >= candidates.length) {
      throw RangeError.range(
        generatedIndex,
        0,
        candidates.length - 1,
        'shuffleIndexGenerator result',
      );
    }
    final target = candidates[generatedIndex];
    _shuffleHistory.add(target);
    _shuffleCursor++;
    return target;
  }

  int? _previousShuffleIndex() {
    if (_shuffleCursor <= 0) {
      return null;
    }
    _shuffleCursor--;
    return _shuffleHistory[_shuffleCursor];
  }

  void _recordShuffleSelection(int index) {
    if (_state.mode != PlaybackMode.shuffle) {
      return;
    }
    if (_shuffleCursor >= 0 && _shuffleHistory[_shuffleCursor] == index) {
      return;
    }
    if (_shuffleCursor + 1 < _shuffleHistory.length) {
      _shuffleHistory.removeRange(_shuffleCursor + 1, _shuffleHistory.length);
    }
    _shuffleHistory.add(index);
    _shuffleCursor = _shuffleHistory.length - 1;
  }

  void _resetShuffleHistory() {
    _shuffleHistory.clear();
    final currentIndex = _state.currentIndex;
    if (currentIndex == null) {
      _shuffleCursor = -1;
      return;
    }
    _shuffleHistory.add(currentIndex);
    _shuffleCursor = 0;
  }

  PlaybackState<T> _setStatus(PlaybackStatus status) {
    if (_state.isEmpty && status != PlaybackStatus.stopped) {
      return _state;
    }
    _state = _state.copyWith(status: status);
    return _state;
  }

  void _checkIndex(int index) => _checkIndexInQueue(index, _state.queue);

  void _checkIndexInQueue(int index, List<T> queue) {
    if (index < 0 || index >= queue.length) {
      throw RangeError.range(index, 0, queue.length - 1, 'index');
    }
  }

  PlaybackStatus _replacementStatus(PlaybackStatus status) {
    switch (status) {
      case PlaybackStatus.loading:
      case PlaybackStatus.playing:
        return PlaybackStatus.loading;
      case PlaybackStatus.paused:
        return PlaybackStatus.paused;
      case PlaybackStatus.stopped:
      case PlaybackStatus.completed:
      case PlaybackStatus.error:
        return PlaybackStatus.stopped;
    }
  }
}
