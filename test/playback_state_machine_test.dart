import 'package:flutter_test/flutter_test.dart';
import 'package:still/services/audio/playback_state.dart';
import 'package:still/services/audio/playback_state_machine.dart';

void main() {
  test('keeps playback snapshots immutable', _testImmutableState);
  test('navigates sequentially and completes at the end',
      _testSequentialNavigation);
  test('supports playlist and single-track loops', _testLoopModes);
  test('keeps deterministic shuffle history', _testDeterministicShuffle);
  test('maintains the current track during queue mutation', _testQueueMutation);
  test('transitions and recovers from errors', _testStatusTransitions);
}

void _testImmutableState() {
  final source = <String>['a', 'b'];
  final machine = PlaybackStateMachine<String>(queue: source);
  final snapshot = machine.state;

  source.add('c');
  _expect(snapshot.queue.length == 2, 'State must copy its input queue.');

  var mutationRejected = false;
  try {
    snapshot.queue.add('c');
  } on UnsupportedError {
    mutationRejected = true;
  }
  _expect(mutationRejected, 'The exposed queue must be unmodifiable.');

  machine.next();
  _expect(snapshot.currentIndex == 0, 'Previous snapshots must not mutate.');
}

void _testSequentialNavigation() {
  final machine = PlaybackStateMachine<String>(queue: ['a', 'b']);

  machine.play();
  _expect(machine.state.status == PlaybackStatus.playing, 'Play failed.');

  machine.next();
  _expect(machine.state.currentTrack == 'b', 'Next must advance.');
  _expect(machine.state.status == PlaybackStatus.loading, 'Next must load.');

  machine.next();
  _expect(
    machine.state.status == PlaybackStatus.completed,
    'Sequential playback must complete at the end.',
  );

  machine.previous();
  _expect(machine.state.currentTrack == 'a', 'Previous must move backward.');
}

void _testLoopModes() {
  final playlistLoop = PlaybackStateMachine<String>(
    queue: ['a', 'b'],
    currentIndex: 1,
    mode: PlaybackMode.playlistLoop,
  );
  playlistLoop.next();
  _expect(playlistLoop.state.currentIndex == 0, 'Playlist loop must wrap.');
  playlistLoop.previous();
  _expect(
    playlistLoop.state.currentIndex == 1,
    'Playlist loop previous must wrap.',
  );

  final singleLoop = PlaybackStateMachine<String>(
    queue: ['a', 'b'],
    mode: PlaybackMode.singleTrackLoop,
  );
  singleLoop.onTrackCompleted();
  _expect(singleLoop.state.currentIndex == 0, 'Single loop must stay put.');
  _expect(
    singleLoop.state.status == PlaybackStatus.loading,
    'Single loop completion must reload the track.',
  );
  singleLoop.next();
  _expect(
    singleLoop.state.currentIndex == 1,
    'Manual next must still advance.',
  );
}

void _testDeterministicShuffle() {
  final generated = <int>[1, 0, 0];
  var call = 0;
  final machine = PlaybackStateMachine<String>(
    queue: ['a', 'b', 'c', 'd'],
    mode: PlaybackMode.shuffle,
    shuffleIndexGenerator: (upperBound) {
      final result = generated[call++];
      _expect(result < upperBound, 'Injected shuffle result is invalid.');
      return result;
    },
  );

  machine.next();
  _expect(machine.state.currentTrack == 'c', 'First shuffle choice failed.');
  machine.next();
  _expect(machine.state.currentTrack == 'b', 'Second shuffle choice failed.');
  machine.previous();
  _expect(
    machine.state.currentTrack == 'c',
    'Shuffle previous must use history.',
  );
  machine.next();
  _expect(machine.state.currentTrack == 'b', 'Shuffle forward history failed.');
  _expect(call == 2, 'History traversal must not consume randomness.');
  machine.next();
  _expect(machine.state.currentTrack == 'd', 'Final shuffle choice failed.');
  machine.next();
  _expect(
    machine.state.status == PlaybackStatus.completed,
    'Shuffle must complete after every track is visited.',
  );
}

void _testQueueMutation() {
  final machine = PlaybackStateMachine<String>(
    queue: ['a', 'b', 'c'],
    currentIndex: 1,
    status: PlaybackStatus.playing,
  );

  machine.insert(0, 'x');
  _expect(
    machine.state.currentTrack == 'b',
    'Insert must preserve current track.',
  );
  _expect(machine.state.currentIndex == 2, 'Insert must adjust current index.');

  machine.removeAt(0);
  _expect(
    machine.state.currentTrack == 'b',
    'Remove must preserve current track.',
  );
  _expect(machine.state.currentIndex == 1, 'Remove must adjust current index.');

  machine.move(1, 2);
  _expect(machine.state.currentTrack == 'b', 'Move must follow current track.');
  _expect(machine.state.currentIndex == 2, 'Move must update current index.');

  machine.removeAt(2);
  _expect(
    machine.state.currentTrack == 'c',
    'Current removal needs replacement.',
  );
  _expect(
    machine.state.status == PlaybackStatus.loading,
    'Replacing a playing current track must load the replacement.',
  );

  machine.clearQueue();
  _expect(machine.state.isEmpty, 'Clear must empty the queue.');
  _expect(
    machine.state.currentIndex == null,
    'Clear must reset current index.',
  );
  _expect(
    machine.state.status == PlaybackStatus.stopped,
    'Clear must stop playback.',
  );
}

void _testStatusTransitions() {
  final machine = PlaybackStateMachine<String>(queue: ['a']);

  machine.markLoading();
  machine.markPlaying();
  machine.markPaused();
  _expect(machine.state.status == PlaybackStatus.paused, 'Pause failed.');

  machine.markError('boom');
  _expect(machine.state.status == PlaybackStatus.error, 'Error failed.');
  _expect(machine.state.errorMessage == 'boom', 'Error message was lost.');

  machine.markLoading();
  _expect(machine.state.errorMessage == null, 'Recovery must clear errors.');
  machine.stop();
  _expect(machine.state.status == PlaybackStatus.stopped, 'Stop failed.');
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
