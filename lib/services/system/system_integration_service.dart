import 'dart:async';

import '../audio/audio_engine.dart';
import 'media_session_service.dart';
import 'system_tray_service.dart';
import 'windows_taskbar_service.dart';

typedef SystemPlaybackCommand = Future<void> Function();

class SystemIntegrationService {
  SystemIntegrationService({
    required this.engine,
    SystemTrayService? tray,
    MediaSessionService? mediaSession,
    WindowsTaskbarService? taskbar,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
  })  : tray = tray ?? SystemTrayService(),
        mediaSession = mediaSession ?? MediaSessionService(),
        taskbar = taskbar ?? WindowsTaskbarService();

  final AudioEngine engine;
  final SystemTrayService tray;
  final MediaSessionService mediaSession;
  final WindowsTaskbarService taskbar;
  final SystemPlaybackCommand? onPlayPause;
  final SystemPlaybackCommand? onPrevious;
  final SystemPlaybackCommand? onNext;
  StreamSubscription<AudioEngineSnapshot>? _snapshotSubscription;
  StreamSubscription<TrayAction>? _traySubscription;
  StreamSubscription<MediaSessionAction>? _mediaSubscription;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await tray.initialize(
      tooltip: 'Still',
      menu: const [
        TrayMenuItem(TrayAction.showWindow, '显示主窗口'),
        TrayMenuItem(TrayAction.playPause, '播放 / 暂停'),
        TrayMenuItem(TrayAction.previous, '上一首'),
        TrayMenuItem(TrayAction.next, '下一首'),
        TrayMenuItem(TrayAction.toggleLyrics, '桌面歌词'),
        TrayMenuItem(TrayAction.toggleTaskbarLyrics, '任务栏歌词'),
        TrayMenuItem(TrayAction.exit, '退出'),
      ],
    );
    _snapshotSubscription = engine.snapshots.listen(_onSnapshot);
    _traySubscription = tray.actions.listen(_onTrayAction);
    _mediaSubscription = mediaSession.actions.listen(_onMediaAction);
    _onSnapshot(engine.snapshot);
  }

  Future<void> dispose() async {
    await _snapshotSubscription?.cancel();
    await _traySubscription?.cancel();
    await _mediaSubscription?.cancel();
    await tray.dispose();
    await mediaSession.dispose();
    _started = false;
  }

  void _onSnapshot(AudioEngineSnapshot snapshot) {
    final track = snapshot.currentTrack;
    final title = track?.title.isNotEmpty == true ? track!.title : 'Still';
    final artist = track?.artist ?? '';
    final label = artist.isEmpty ? title : '$title - $artist';
    unawaited(tray.setTooltip(label));
    unawaited(tray.setPlaying(snapshot.playback.isPlaying));
    unawaited(taskbar.setTitle('$label | Still'));
    final duration = snapshot.duration;
    if (duration != null && duration.inMicroseconds > 0) {
      unawaited(taskbar.setProgress(
          value: snapshot.position.inMicroseconds / duration.inMicroseconds));
    }
    if (track != null) {
      unawaited(mediaSession.setMetadata(MediaSessionMetadata(
          title: title,
          artist: artist,
          album: track.album,
          duration: duration ?? Duration.zero)));
    }
    unawaited(mediaSession.setPlaybackState(
        playing: snapshot.playback.isPlaying,
        position: snapshot.position,
        speed: snapshot.speed));
  }

  void _onTrayAction(TrayAction action) {
    switch (action) {
      case TrayAction.playPause:
        unawaited(onPlayPause?.call());
      case TrayAction.previous:
        unawaited(onPrevious?.call());
      case TrayAction.next:
        unawaited(onNext?.call());
      case TrayAction.showWindow ||
            TrayAction.toggleLyrics ||
            TrayAction.toggleTaskbarLyrics ||
            TrayAction.exit:
        break;
    }
  }

  void _onMediaAction(MediaSessionAction action) {
    switch (action) {
      case MediaSessionAction.play || MediaSessionAction.pause:
        unawaited(onPlayPause?.call());
      case MediaSessionAction.previous:
        unawaited(onPrevious?.call());
      case MediaSessionAction.next:
        unawaited(onNext?.call());
      case MediaSessionAction.seek:
        break;
    }
  }
}
