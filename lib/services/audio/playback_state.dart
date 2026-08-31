enum PlaybackMode { sequential, shuffle, playlistLoop, singleTrackLoop }

enum PlaybackStatus { stopped, loading, playing, paused, completed, error }

final class PlaybackState<T> {
  PlaybackState({
    Iterable<T> queue = const [],
    this.currentIndex,
    this.mode = PlaybackMode.sequential,
    this.status = PlaybackStatus.stopped,
    this.errorMessage,
  }) : queue = List<T>.unmodifiable(queue) {
    _validateCurrentIndex(this.queue, currentIndex);
    if (status == PlaybackStatus.error && errorMessage == null) {
      throw ArgumentError('An error state must include an error message.');
    }
    if (status != PlaybackStatus.error && errorMessage != null) {
      throw ArgumentError('Only an error state may include an error message.');
    }
  }

  final List<T> queue;
  final int? currentIndex;
  final PlaybackMode mode;
  final PlaybackStatus status;
  final String? errorMessage;

  bool get isEmpty => queue.isEmpty;
  bool get isNotEmpty => queue.isNotEmpty;
  bool get hasCurrentTrack => currentIndex != null;
  bool get isPlaying => status == PlaybackStatus.playing;
  bool get isPaused => status == PlaybackStatus.paused;
  bool get isLoading => status == PlaybackStatus.loading;

  T? get currentTrack {
    final index = currentIndex;
    return index == null ? null : queue[index];
  }

  PlaybackState<T> copyWith({
    Iterable<T>? queue,
    Object? currentIndex = _notProvided,
    PlaybackMode? mode,
    PlaybackStatus? status,
    Object? errorMessage = _notProvided,
  }) {
    final nextStatus = status ?? this.status;
    final nextErrorMessage = identical(errorMessage, _notProvided)
        ? (nextStatus == PlaybackStatus.error ? this.errorMessage : null)
        : errorMessage as String?;

    return PlaybackState<T>(
      queue: queue ?? this.queue,
      currentIndex: identical(currentIndex, _notProvided)
          ? this.currentIndex
          : currentIndex as int?,
      mode: mode ?? this.mode,
      status: nextStatus,
      errorMessage: nextErrorMessage,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PlaybackState<T> &&
            _listEquals(queue, other.queue) &&
            currentIndex == other.currentIndex &&
            mode == other.mode &&
            status == other.status &&
            errorMessage == other.errorMessage;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(queue),
        currentIndex,
        mode,
        status,
        errorMessage,
      );

  @override
  String toString() {
    return 'PlaybackState('
        'queueLength: ${queue.length}, '
        'currentIndex: $currentIndex, '
        'mode: $mode, '
        'status: $status, '
        'errorMessage: $errorMessage)';
  }

  static void _validateCurrentIndex<T>(List<T> queue, int? currentIndex) {
    if (queue.isEmpty && currentIndex != null) {
      throw RangeError.value(
        currentIndex,
        'currentIndex',
        'must be null when the queue is empty',
      );
    }
    if (currentIndex != null &&
        (currentIndex < 0 || currentIndex >= queue.length)) {
      throw RangeError.range(currentIndex, 0, queue.length - 1, 'currentIndex');
    }
  }

  static bool _listEquals<T>(List<T> left, List<T> right) {
    if (identical(left, right)) {
      return true;
    }
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}

const Object _notProvided = Object();
