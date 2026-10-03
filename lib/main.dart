import 'dart:ui';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:metadata_god/metadata_god.dart';

import 'widgets/lyrics_effects.dart';

import 'core/utils/pinyin_utils.dart';
import 'core/utils/lrc_parser.dart';
import 'services/lyrics_tools.dart';
import 'services/audio/playback_state.dart';
import 'services/localization_service.dart';
import 'services/audio/audio_engine.dart';
import 'services/audio/audio_track.dart';
import 'services/audio/miniaudio_backend.dart';
import 'models/song.dart';
import 'services/database_service.dart';
import 'services/playback_memory_service.dart';
import 'services/scanner_service.dart';
import 'services/metadata_cache_service.dart';
import 'services/system/system_integration_service.dart';
import 'services/desktop/desktop_window_service.dart';
import 'services/window_state_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MetadataGod.initialize();
  runApp(const ProviderScope(child: StillApp()));
}

class StillApp extends StatefulWidget {
  const StillApp({super.key});

  @override
  State<StillApp> createState() => _StillAppState();
}

class _StillAppState extends State<StillApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  final WindowStateService _windowState = WindowStateService();

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      _windowState.initialize().catchError((_) {});
    }
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() => _themeMode = prefs.getBool('dark_mode') == false
          ? ThemeMode.light
          : ThemeMode.dark);
    });
  }

  @override
  void dispose() {
    _windowState.persist().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff63d6c6),
      brightness:
          _themeMode == ThemeMode.dark ? Brightness.dark : Brightness.light,
    );
    return AnimatedTheme(
      data: ThemeData(
          colorScheme: scheme, useMaterial3: true, fontFamily: 'Segoe UI'),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Still',
        localizationsDelegates: const [
          StillLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        themeMode: _themeMode,
        theme: ThemeData(
            colorScheme: scheme, useMaterial3: true, fontFamily: 'Segoe UI'),
        home: MainShell(
          themeMode: _themeMode,
          onThemeChanged: (mode) {
            setState(() => _themeMode = mode);
            SharedPreferences.getInstance()
                .then((p) => p.setBool('dark_mode', mode == ThemeMode.dark));
          },
        ),
      ),
    );
  }
}

class Track {
  const Track(this.title, this.artist, this.album, this.duration, this.format,
      this.color,
      [this.path = '', this.coverPath = '', this.embeddedLyrics = '',
      this.year = '']);
  final String title;
  final String artist;
  final String album;
  final String duration;
  final String format;
  final Color color;
  final String path;
  final String coverPath;
  final String embeddedLyrics;
  final String year;
}

final tracks = <Track>[];

enum LibraryPage {
  songs,
  artists,
  artistDetail,
  albums,
  albumDetail,
  library,
  folders,
  folderDetail,
  playlists,
  playlistDetail,
  stats,
  unreadable,
  settings
}

class _PageEntry {
  const _PageEntry({
    required this.page,
    this.artist,
    this.album,
    this.folderPath = '',
    this.playlist,
  });

  final LibraryPage page;
  final String? artist;
  final String? album;
  final String folderPath;
  final String? playlist;
}

class MainShell extends StatefulWidget {
  const MainShell(
      {super.key, required this.themeMode, required this.onThemeChanged});
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  LibraryPage _page = LibraryPage.songs;
  final List<_PageEntry> _history = <_PageEntry>[];
  bool _sidebarExpanded = true;
  bool _playing = false;
  bool _shuffle = false;
  double _volume = .72;
  double _playbackSpeed = 1;
  bool _muted = false;
  bool _desktopLyricsVisible = false;
  PlaybackMode _loopMode = PlaybackMode.sequential;
  Duration _position = Duration.zero;
  final ValueNotifier<Duration> _lyricsPosition = ValueNotifier(Duration.zero);
  String _query = '';
  String _sort = '添加时间';
  bool _grid = false;
  bool _dragActive = false;
  bool _scanning = false;
  double _scanProgress = 0;
  String? _scanStatus;
  int _current = 0;
  int? _locatedTrackIndex;
  String? _selectedArtist;
  String? _selectedAlbum;
  String _folderPath = '';
  String? _selectedPlaylist;
  final List<String> _folders = <String>[];
  final Map<String, List<Track>> _playlists = <String, List<Track>>{};
  final Set<Track> _unreadable = <Track>{};
  final Set<Track> _selectedTracks = <Track>{};
  bool _selectionMode = false;
  int? _lastTappedIndex;
  AudioEngine? _audioEngine;
  StreamSubscription<AudioEngineSnapshot>? _audioSubscription;
  final DatabaseService _database = DatabaseService();
  final PlaybackMemoryService _playbackMemory = PlaybackMemoryService();
  final DesktopWindowService _desktopWindowService = DesktopWindowService();
  SystemIntegrationService? _systemIntegration;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        _audioEngine = AudioEngine(backend: MiniaudioBackend());
        _audioSubscription = _audioEngine!.snapshots.listen((snapshot) {
          if (!mounted) return;
          setState(() {
            _playing = snapshot.playback.isPlaying;
            _position = snapshot.position;
            _lyricsPosition.value = snapshot.position;
            _volume = snapshot.volume;
            _playbackSpeed = snapshot.speed;
            _loopMode = snapshot.playback.mode;
            final path = snapshot.currentTrack?.filePath;
            if (path != null) {
              final index = tracks.indexWhere((track) => track.path == path);
              if (index >= 0) _current = index;
            }
          });
        });
        _systemIntegration = SystemIntegrationService(
          engine: _audioEngine!,
          onPlayPause: _togglePlayback,
          onPrevious: () =>
              _playIndex((_current - 1 + tracks.length) % tracks.length),
          onNext: () => _playIndex((_current + 1) % tracks.length),
        );
        unawaited(_audioEngine!.initialize().catchError((_) {}));
        unawaited(_systemIntegration!.start());
      } catch (_) {
        _audioEngine = null;
      }
    }
    unawaited(_restoreLibrary());
  }

  @override
  void dispose() {
    _audioSubscription?.cancel();
    _systemIntegration?.dispose();
    _audioEngine?.dispose();
    _lyricsPosition.dispose();
    super.dispose();
  }

  Future<void> _restoreLibrary() async {
    final savedFolders = await _database.folders();
    final savedSongs = await _database.songs();
    if (!mounted) return;
    final existingSongs = <Song>[];
    final missingSongs = <Song>[];
    for (final song in savedSongs) {
      if (song.path.isNotEmpty && await File(song.path).exists()) {
        existingSongs.add(song);
      } else {
        missingSongs.add(song);
      }
    }
    setState(() {
      _unreadable
        ..clear()
        ..addAll(missingSongs.map(_trackFromSong));
      if (savedFolders.isNotEmpty) {
        _folders
          ..clear()
          ..addAll(savedFolders);
      }
      if (existingSongs.isNotEmpty) {
        tracks
          ..clear()
          ..addAll(existingSongs.map(_trackFromSong));
      } else {
        tracks.clear();
      }
    });
    final preferences = await SharedPreferences.getInstance();
    final currentVersion = preferences.getInt('metadata_schema_version');
    if (currentVersion == 3) return;
    await MetadataCacheService().clear();
    final roots = <String>{
      ...savedFolders,
      ...existingSongs.map((song) => song.path),
    }..removeWhere((path) => path.isEmpty);
    if (roots.isNotEmpty) {
      await _scanPaths(roots, folders: savedFolders);
    }
    await preferences.setInt('metadata_schema_version', 3);
  }

  static Track _trackFromSong(Song song) => Track(
        song.title.isEmpty ? song.fileName : song.title,
        song.artist.isEmpty ? '未知艺术家' : song.artist,
        song.album.isEmpty ? '未知专辑' : song.album,
        _formatSongDuration(song.duration),
        song.format.isEmpty ? '音频' : song.format,
        _colorFromHash(song.title.hashCode),
        song.path,
        (song.coverArtPath != null && File(song.coverArtPath!).existsSync())
            ? song.coverArtPath!
            : '',
        song.embeddedLyrics ?? '',
      );

  static final _palette = [
    const Color(0xff365a68),
    const Color(0xffc08b58),
    const Color(0xff516c68),
    const Color(0xff524c72),
    const Color(0xffb66555),
    const Color(0xff7e654c),
    const Color(0xff93675e),
    const Color(0xff4b607b),
    const Color(0xff6b5b73),
    const Color(0xff8a6d5b),
    const Color(0xff5a7c6b),
    const Color(0xff7b6a8a),
    const Color(0xffa0705a),
    const Color(0xff4e6e7e),
    const Color(0xff6e8060),
    const Color(0xff8c5e5e),
  ];

  static Color _colorFromHash(int hash) =>
      _palette[hash.abs() % _palette.length];

  Future<void> _playIndex(int index) async {
    final snapshot = List<Track>.from(tracks);
    if (index < 0 || index >= snapshot.length) return;
    final engine = _audioEngine;
    final selectedTrack = snapshot[index];
    if (engine == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('音频引擎初始化失败，无法播放')),
        );
      }
      return;
    }
    if (selectedTrack.path.isEmpty ||
        !await File(selectedTrack.path).exists()) {
      if (mounted) {
        setState(() => _unreadable.add(selectedTrack));
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('无法播放此歌曲'),
            content:
                Text('${selectedTrack.title} 可能已被移动、删除或当前没有读取权限。是否从音乐库中移除？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('暂不移除')),
              FilledButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    setState(() {
                      tracks.removeWhere(
                          (track) => track.path == selectedTrack.path);
                      _unreadable.remove(selectedTrack);
                      if (tracks.isNotEmpty)
                        _current = _current.clamp(0, tracks.length - 1);
                    });
                  },
                  child: const Text('从音乐库移除')),
            ],
          ),
        );
      }
      return;
    }
    final playableTracks = <Track>[];
    for (final track in snapshot) {
      if (track.path.isNotEmpty && await File(track.path).exists()) {
        playableTracks.add(track);
      }
    }
    playableTracks
      ..removeWhere((track) => track.path == selectedTrack.path)
      ..insert(0, selectedTrack);
    setState(() {
      _current = snapshot.indexOf(selectedTrack);
      _playing = true;
    });
    final queue = [
      for (var i = 0; i < playableTracks.length; i++)
        AudioTrack(
            id: i,
            filePath: playableTracks[i].path,
            title: playableTracks[i].title,
            artist: playableTracks[i].artist,
            album: playableTracks[i].album,
            duration: _parseDuration(playableTracks[i].duration)),
    ];
    try {
      await engine.loadQueue(queue, initialIndex: 0, autoplay: true);
      await engine.setMode(_shuffle ? PlaybackMode.shuffle : _loopMode);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _unreadable.add(selectedTrack);
      });
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法播放此歌曲'),
          content: Text(
              '${selectedTrack.title} 播放失败：$error\n\n是否从音乐库中移除？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('暂不移除')),
            FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  setState(() {
                    tracks.removeWhere(
                        (track) => track.path == selectedTrack.path);
                    _unreadable.remove(selectedTrack);
                    if (tracks.isNotEmpty) {
                      _current = _current.clamp(0, tracks.length - 1);
                    }
                  });
                },
                child: const Text('从音乐库移除')),
          ],
        ),
      );
    }
  }

  void _playFromSubset(List<Track> subset, int index) {
    if (subset.isEmpty) return;
    final selected = subset[index.clamp(0, subset.length - 1)];
    final globalIndex = tracks.indexOf(selected);
    if (globalIndex >= 0) unawaited(_playIndex(globalIndex));
  }

  Future<void> _togglePlayback() async {
    if (_playing) {
      await _audioEngine?.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      await _playIndex(_current);
      if (_audioEngine == null && mounted) setState(() => _playing = true);
    }
  }

  void _locateCurrentTrack() {
    if (tracks.isEmpty || _current < 0 || _current >= tracks.length) return;
    setState(() => _locatedTrackIndex = _current);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = PrimaryScrollController.of(context);
      if (controller.hasClients) {
        final targetOffset = (_current * 76.0).clamp(
          controller.position.pixels,
          controller.position.maxScrollExtent,
        );
        controller.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _locatedTrackIndex = null);
    });
  }

  static Duration _parseDuration(String value) {
    final parts = value.split(':').map(int.tryParse).toList();
    if (parts.length == 2 && parts[0] != null && parts[1] != null)
      return Duration(minutes: parts[0]!, seconds: parts[1]!);
    return Duration.zero;
  }

  Track get currentTrack => tracks.isEmpty
      ? const Track('', '', '', '', '', Colors.grey)
      : tracks[_current.clamp(0, tracks.length - 1)];

  void _select(LibraryPage page) {
    if (page == _page) return;
    setState(() {
      _history.add(_currentEntry());
      _page = page;
    });
  }

  _PageEntry _currentEntry() => _PageEntry(
        page: _page,
        artist: _selectedArtist,
        album: _selectedAlbum,
        folderPath: _folderPath,
        playlist: _selectedPlaylist,
      );

  void _openArtist(String artist) => setState(() {
        _history.add(_currentEntry());
        _selectedArtist = artist;
        _page = LibraryPage.artistDetail;
      });

  void _openAlbum(String album) => setState(() {
        _history.add(_currentEntry());
        _selectedAlbum = album;
        _page = LibraryPage.albumDetail;
      });

  void _openFolder(String path) => setState(() {
        _history.add(_currentEntry());
        _folderPath = path;
        _page = LibraryPage.folderDetail;
      });

  void _openPlaylist(String name) => setState(() {
        _history.add(_currentEntry());
        _selectedPlaylist = name;
        _page = LibraryPage.playlistDetail;
      });

  void _goBack() {
    if (_history.isEmpty) return;
    final previous = _history.removeLast();
    setState(() {
      _page = previous.page;
      _selectedArtist = previous.artist;
      _selectedAlbum = previous.album;
      _folderPath = previous.folderPath;
      _selectedPlaylist = previous.playlist;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragActive = true),
      onDragExited: (_) => setState(() => _dragActive = false),
      onDragDone: (detail) {
        print('[DropTarget] onDragDone: files=${detail.files.map((f) => f.path).toList()}');
        setState(() => _dragActive = false);
        unawaited(_handleDroppedPaths(detail.files.map((file) => file.path)));
      },
      child: Stack(children: [
        Scaffold(
          backgroundColor:
              isDark ? const Color(0xff111318) : const Color(0xfff4f6f6),
          body: LayoutBuilder(builder: (context, constraints) {
            final compact = constraints.maxWidth < 820;
            final sidebar = compact ? false : _sidebarExpanded;
            return Stack(children: [
              Column(children: [
                _TitleBar(
                    page: _page,
                    canGoBack: _history.isNotEmpty,
                    onBack: _goBack,
                    onForward: () {},
                    onSettings: () => _select(LibraryPage.settings),
                    unreadableCount: _unreadable.length,
                    scanning: _scanning,
                    scanProgress: _scanProgress,
                    onUnreadable: () => _select(LibraryPage.unreadable)),
                Expanded(
                    child: Row(children: [
                  _Sidebar(
                      expanded: sidebar,
                      page: _page,
                      onSelect: _select,
                      playlists: _playlists,
                      selectedPlaylist: _selectedPlaylist,
                      onPlaylist: _openPlaylist,
                      onCreatePlaylist: _createPlaylist,
                      onToggle: () =>
                          setState(() => _sidebarExpanded = !_sidebarExpanded)),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 96),
                      child: _buildPage(),
                    ),
                  ),
                ])),
              ]),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _PlaybackBar(
                  track: currentTrack,
                  playing: _playing,
                  mode: _shuffle ? PlaybackMode.shuffle : _loopMode,
                  volume: _volume,
                  speed: _playbackSpeed,
                  desktopLyricsVisible: _desktopLyricsVisible,
                  onPlay: _togglePlayback,
                  onPrevious: () async => _playIndex(
                      (_current - 1 + tracks.length) % tracks.length),
                  onNext: () async =>
                      _playIndex((_current + 1) % tracks.length),
                  onStop: () async {
                    await _audioEngine?.stop();
                    if (mounted)
                      setState(() {
                        _playing = false;
                        _position = Duration.zero;
                      });
                  },
                  onVolume: (v) async {
                    setState(() => _volume = v);
                    await _audioEngine?.setVolume(v);
                  },
                  muted: _muted,
                  onMute: () async {
                    final nextMuted = !_muted;
                    setState(() => _muted = nextMuted);
                    await _audioEngine?.setVolume(nextMuted ? 0 : _volume);
                  },
                  onMode: () async {
                    final currentMode =
                        _shuffle ? PlaybackMode.shuffle : _loopMode;
                    final mode = switch (currentMode) {
                      PlaybackMode.sequential => PlaybackMode.playlistLoop,
                      PlaybackMode.playlistLoop => PlaybackMode.singleTrackLoop,
                      PlaybackMode.singleTrackLoop => PlaybackMode.shuffle,
                      PlaybackMode.shuffle => PlaybackMode.sequential,
                    };
                    setState(() {
                      _shuffle = mode == PlaybackMode.shuffle;
                      _loopMode = mode == PlaybackMode.shuffle
                          ? PlaybackMode.sequential
                          : mode;
                    });
                    await _audioEngine?.setMode(mode);
                  },
                  position: _position,
                  onSeek: (value) async {
                    setState(() => _position = value);
                    _lyricsPosition.value = value;
                    await _audioEngine?.seek(value);
                    await _playbackMemory.save(currentTrack.path, value);
                  },
                  onLyrics: () => _showLyrics(context),
                  onDesktopLyrics: () async {
                    final next = !_desktopLyricsVisible;
                    setState(() => _desktopLyricsVisible = next);
                    if (next) {
                      await _desktopWindowService
                          .show(DesktopWindowKind.lyrics);
                    } else {
                      await _desktopWindowService
                          .hide(DesktopWindowKind.lyrics);
                    }
                  },
                  onSpeed: (speed) async {
                    setState(() => _playbackSpeed = speed);
                    await _audioEngine?.setSpeed(speed);
                  },
                  onPlaylist: () => _showQueue(context),
                ),
              ),
              if (tracks.isNotEmpty && _current >= 0 && _current < tracks.length)
                Positioned(
                  right: 28,
                  bottom: 108,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      onPressed: _locateCurrentTrack,
                      icon: const Icon(Icons.my_location, size: 22),
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface.withOpacity(.95),
                        foregroundColor: Theme.of(context).colorScheme.onSurface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: Theme.of(context).dividerColor.withOpacity(.45),
                          ),
                        ),
                        elevation: 4,
                      ),
                    ),
                  ),
                ),
            ]);
          }),
        ),
        if (_dragActive)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _dragActive ? 1.0 : 0.0,
                child: Container(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: .08),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 36, vertical: 24),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surface
                            .withOpacity(.95),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(.15),
                            blurRadius: 32,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.library_music,
                              size: 52,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(height: 12),
                          Text('拖放音乐文件或文件夹到此处',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text('支持 MP3、FLAC、M4A、WAV 等格式',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (_scanning)
          Positioned(
            left: 24,
            right: 24,
            bottom: 86,
            child: Material(
              elevation: 4,
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_scanStatus ?? '正在扫描...')),
                  SizedBox(
                    width: 110,
                    child: LinearProgressIndicator(value: _scanProgress),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildPage() {
    switch (_page) {
      case LibraryPage.songs:
        return SongsPage(
            query: _query,
            sort: _sort,
            grid: _grid,
            playing: _playing,
            current: _current,
            locatedTrackIndex: _locatedTrackIndex,
            onQuery: (v) => setState(() => _query = v),
            onSort: (v) => setState(() => _sort = v),
            onGrid: () => setState(() => _grid = !_grid),
            onPlay: _playIndex,
            onArtist: _openArtist,
            onAlbum: _openAlbum,
            selectionMode: _selectionMode,
            selectedTracks: _selectedTracks,
            onToggleSelection: (track) => setState(() {
                  if (!_selectedTracks.add(track))
                    _selectedTracks.remove(track);
                }),
            onToggleSelectionMode: () => setState(() {
                  _selectionMode = !_selectionMode;
                  if (!_selectionMode) _selectedTracks.clear();
                }),
            onSelectAll: () => setState(() {
                  if (_selectedTracks.length == tracks.length) {
                    _selectedTracks.clear();
                  } else {
                    _selectedTracks.addAll(tracks);
                  }
                }),
            onAddSelectedToPlaylist: () => _addToPlaylistDialog(),
            onDeleteSelected: () => _deleteSelectedDialog(),
            lastTappedIndex: _lastTappedIndex,
            playlists: _playlists,
            onRangeSelect: (index, shift) {
              if (shift && _lastTappedIndex != null) {
                final start = _lastTappedIndex!;
                final end = index;
                final low = start < end ? start : end;
                final high = start < end ? end : start;
                setState(() {
                  for (var i = low; i <= high; i++) {
                    _selectedTracks.add(tracks[i]);
                  }
                  _lastTappedIndex = index;
                });
              } else if (!shift) {
                setState(() {
                  _lastTappedIndex = index;
                  final track = tracks[index];
                  if (!_selectedTracks.add(track)) {
                    _selectedTracks.remove(track);
                  }
                });
              }
            },
            onBatchContext: () {
              if (_selectedTracks.isNotEmpty) {
                _showBatchContextMenu(context, _selectedTracks,
                    playlists: _playlists,
                    onDelete: () => _deleteSelectedDialog(),
                    onClearSelection: () => setState(() {
                          _selectedTracks.clear();
                          _selectionMode = false;
                        }));
              }
            });
      case LibraryPage.artists:
        final artistCounts = <String, int>{};
        for (final t in tracks) {
          final a = t.artist.isEmpty ? '未知艺术家' : t.artist;
          artistCounts[a] = (artistCounts[a] ?? 0) + 1;
        }
        final sortedArtists = artistCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        return CollectionPage(
            title: '艺术家',
            subtitle: '${sortedArtists.length} 位艺术家',
            icon: Icons.person_outline,
            labels: sortedArtists.take(50).map((e) => e.key).toList(),
            counts:
                sortedArtists.take(50).map((e) => '${e.value} 首歌曲').toList(),
            onTap: _openArtist);
      case LibraryPage.artistDetail:
        return ArtistDetailPage(
            artist: _selectedArtist ?? '',
            onAlbum: _openAlbum,
            onPlay: (i) => _playFromSubset(
                tracks.where((t) => t.artist == _selectedArtist).toList(), i));
      case LibraryPage.albums:
        final albumCounts = <String, int>{};
        for (final t in tracks) {
          final a = t.album.isEmpty ? '未知专辑' : t.album;
          albumCounts[a] = (albumCounts[a] ?? 0) + 1;
        }
        final sortedAlbums = albumCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        return CollectionPage(
            title: '专辑',
            subtitle: '${sortedAlbums.length} 张专辑',
            icon: Icons.album_outlined,
            labels: sortedAlbums.take(50).map((e) => e.key).toList(),
            counts: sortedAlbums.take(50).map((e) => '${e.value} 首歌曲').toList(),
            onTap: _openAlbum);
      case LibraryPage.albumDetail:
        return AlbumDetailPage(
            album: _selectedAlbum ?? '',
            onArtist: _openArtist,
            onPlay: (i) => _playFromSubset(
                tracks.where((t) => t.album == _selectedAlbum).toList(), i));
      case LibraryPage.library:
        return MusicLibraryPage(
            folders: _folders,
            onAdd: _addFolder,
            onRefresh: () => _scanPaths(_folders, folders: _folders),
            unreadableCount: _unreadable.length,
            onUnreadable: () => _select(LibraryPage.unreadable));
      case LibraryPage.folders:
        return FoldersPage(
            folders: _folders, songs: tracks, onOpen: _openFolder);
      case LibraryPage.folderDetail:
        return FolderDetailPage(
            path: _folderPath,
            onBack: _goBack,
            onOpen: _openFolder,
            onPlay: (track) => unawaited(_playIndex(tracks.indexOf(track))));
      case LibraryPage.playlists:
        return PlaylistsPage(
            playlists: _playlists,
            onCreate: _createPlaylist,
            onDelete: _deletePlaylist,
            onRename: _renamePlaylist,
            onOpen: _openPlaylist);
      case LibraryPage.playlistDetail:
        final name = _selectedPlaylist ?? '';
        return PlaylistDetailPage(
            name: name,
            songs: _playlists[name] ?? const [],
            onAdd: (t) => setState(() {
                  final l = _playlists[name]!;
                  if (!l.contains(t)) l.add(t);
                }),
            onRemove: (t) => setState(() => _playlists[name]?.remove(t)),
            onReorder: (a, b) => setState(() {
                  final l = _playlists[name]!;
                  final x = l.removeAt(a);
                  l.insert(b > a ? b - 1 : b, x);
                }),
            onPlay: (track) => unawaited(_playIndex(tracks.indexOf(track))),
            onArtist: _openArtist,
            onAlbum: _openAlbum);
      case LibraryPage.stats:
        return StatsPage(library: tracks);
      case LibraryPage.unreadable:
        return UnreadablePage(
            items: _unreadable,
            onRelink: _relink,
            onRemove: (t) => unawaited(_removeTrackFromLibrary(t)),
            onRemoveAll: () => unawaited(_removeAllUnreadable()),
            onPlay: (track) => unawaited(_playIndex(tracks.indexOf(track))),
            onArtist: _openArtist,
            onAlbum: _openAlbum);
      case LibraryPage.settings:
        return SettingsPage(
            themeMode: widget.themeMode, onThemeChanged: widget.onThemeChanged);
    }
  }

  Future<void> _addFolder() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('添加文件夹'),
                content: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: '输入文件夹路径')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, controller.text.trim()),
                      child: const Text('扫描'))
                ]));
    if (path == null || path.isEmpty) return;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('路径不是可扫描的文件夹')));
      return;
    }
    await _scanPaths([path], folders: [path]);
  }

  Future<void> _handleDroppedPaths(Iterable<String> paths) async {
    print('[_handleDroppedPaths] paths: ${paths.toList()}');
    if (_scanning) return;
    final roots = <String>[];
    final folders = <String>[];
    final seen = <String>{};
    for (final path in paths) {
      if (!seen.add(path)) continue;
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        roots.add(path);
        folders.add(path);
      } else if (type == FileSystemEntityType.file &&
          ScannerService.supportedExtensions.contains(_extension(path))) {
        roots.add(path);
      }
    }
    if (roots.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('没有找到可扫描的音乐文件')));
      return;
    }
    await _scanPaths(roots, folders: folders);
  }

  Future<void> _scanPaths(Iterable<String> roots,
      {Iterable<String> folders = const []}) async {
    final scanRoots = roots.toSet().toList(growable: false);
    if (scanRoots.isEmpty || _scanning) return;
    if (mounted) {
      setState(() {
        _scanning = true;
        _scanProgress = 0;
        _scanStatus = '正在准备扫描...';
        for (final folder in folders) {
          if (!_folders.contains(folder)) _folders.add(folder);
        }
      });
    }
    try {
      await _database.saveFolders(_folders);
      final songs =
          await ScannerService().scan(scanRoots, onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          _scanProgress = progress.fraction;
          _scanStatus = '已扫描 ${progress.scanned}/${progress.total} 首';
        });
      });
      final storedSongs = await _database.songs();
      final scannedPaths = <String>{for (final song in songs) song.path};
      final songsByPath = <String, Song>{
        for (final song in storedSongs) song.path: song,
        for (final song in songs) song.path: song,
      };
      // 清理数据库中已不存在的文件（文件被删除/移动后刷新检测）
      final removedPaths = <String>{};
      for (final path in songsByPath.keys.toList()) {
        if (!scannedPaths.contains(path) && !await File(path).exists()) {
          songsByPath.remove(path);
          removedPaths.add(path);
        }
      }
      await _database.saveSongs(songsByPath.values);
      if (mounted) {
        setState(() {
          // 添加或更新数据库中所有存在的歌曲
          final mergedSongs = songsByPath.values;
          for (final song in mergedSongs) {
            final index =
                tracks.indexWhere((track) => track.path == song.path);
            if (index == -1) {
              tracks.add(_trackFromSong(song));
            } else {
              tracks[index] = _trackFromSong(song);
            }
          }
          // 移除已不存在的歌曲
          if (removedPaths.isNotEmpty) {
            tracks.removeWhere((t) => removedPaths.contains(t.path));
            _unreadable.removeWhere((t) => removedPaths.contains(t.path));
            if (tracks.isNotEmpty) {
              _current = _current.clamp(0, tracks.length - 1);
            }
          }
        });
      }
      final prefs = await SharedPreferences.getInstance();
      for (final path in scanRoots) {
        await prefs.setInt(
            'scan_${path.hashCode}', DateTime.now().millisecondsSinceEpoch);
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('扫描完成，发现 ${songs.length} 首歌曲')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('扫描失败：$error')));
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          _scanProgress = 0;
          _scanStatus = null;
        });
      }
    }
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  static String _formatSongDuration(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  void _createPlaylist() async {
    final c = TextEditingController();
    final n = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('新建歌单'),
                content: TextField(controller: c, autofocus: true),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, c.text.trim()),
                      child: const Text('创建'))
                ]));
    if (n != null && n.isNotEmpty) setState(() => _playlists[n] = []);
  }

  void _deletePlaylist(String n) => setState(() => _playlists.remove(n));

  void _addToPlaylistDialog() {
    if (_selectedTracks.isEmpty) return;
    final names = _playlists.keys.toList();
    showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
                title: Text('添加 ${_selectedTracks.length} 首歌曲到歌单'),
                content: SizedBox(
                  width: 300,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: names.length + 1,
                    itemBuilder: (_, index) {
                      if (index == names.length) {
                        return ListTile(
                          leading: const Icon(Icons.add),
                          title: const Text('新建歌单'),
                          onTap: () {
                            Navigator.pop(context);
                            final ctrl = TextEditingController();
                            showDialog<String>(
                                context: context,
                                builder: (_) => AlertDialog(
                                        title: const Text('新建歌单'),
                                        content: TextField(
                                            controller: ctrl,
                                            autofocus: true),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('取消')),
                                          FilledButton(
                                              onPressed: () => Navigator.pop(
                                                  context, ctrl.text.trim()),
                                              child: const Text('创建'))
                                        ])).then((n) {
                              if (n != null && n.isNotEmpty) {
                                setState(() => _playlists[n] = []);
                                setState(() {
                                  for (final t in _selectedTracks) {
                                    if (!_playlists[n]!.contains(t)) {
                                      _playlists[n]!.add(t);
                                    }
                                  }
                                });
                              }
                            });
                          },
                        );
                      }
                      return ListTile(
                        leading: const Icon(Icons.queue_music),
                        title: Text(names[index]),
                        subtitle: Text('${_playlists[names[index]]!.length} 首歌曲'),
                        onTap: () {
                          Navigator.pop(context);
                          setState(() {
                            for (final t in _selectedTracks) {
                              if (!_playlists[names[index]]!.contains(t)) {
                                _playlists[names[index]]!.add(t);
                              }
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                ]));
  }

  void _deleteSelectedDialog() {
    if (_selectedTracks.isEmpty) return;
    final count = _selectedTracks.length;
    showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('删除歌曲'),
                content: Text('确定从库中删除选中的 $count 首歌曲？\n此操作不会删除实际文件。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除')),
                ])).then((confirmed) {
      if (confirmed != true) return;
      final paths = _selectedTracks.map((t) => t.path).toSet();
      setState(() {
        tracks.removeWhere((t) => paths.contains(t.path));
        _selectedTracks.clear();
        _selectionMode = false;
        if (tracks.isNotEmpty) _current = _current.clamp(0, tracks.length - 1);
      });
      _database.songs().then((saved) async {
        await _database.saveSongs(
            saved.where((song) => !paths.contains(song.path)).toList());
      });
    });
  }

  Future<void> _removeTrackFromLibrary(Track track) async {
    setState(() {
      tracks.removeWhere((item) => item.path == track.path);
      _unreadable.removeWhere((item) => item.path == track.path);
      if (tracks.isNotEmpty) _current = _current.clamp(0, tracks.length - 1);
    });
    final saved = await _database.songs();
    await _database.saveSongs(
        saved.where((song) => song.path != track.path).toList());
  }

  Future<void> _removeAllUnreadable() async {
    final paths = _unreadable.map((track) => track.path).toSet();
    setState(() => _unreadable.clear());
    final saved = await _database.songs();
    await _database.saveSongs(
        saved.where((song) => !paths.contains(song.path)).toList());
  }

  void _renamePlaylist(String oldName) async {
    final c = TextEditingController(text: oldName);
    final n = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('重命名歌单'),
                content: TextField(controller: c, autofocus: true),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, c.text.trim()),
                      child: const Text('保存'))
                ]));
    if (n != null && n.isNotEmpty && n != oldName)
      setState(() {
        _playlists[n] = _playlists.remove(oldName)!;
      });
  }

  void _relink(Track t) async {
    final c = TextEditingController(text: t.path);
    final p = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('重新链接文件'),
                content: TextField(controller: c),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, c.text),
                      child: const Text('确定'))
                ]));
    if (p != null) setState(() => _unreadable.remove(t));
  }

  void _showLyrics(BuildContext context) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭歌词',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (_, __, ___) =>
          LyricsSheet(track: currentTrack, positionListenable: _lyricsPosition),
      transitionBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        child: ScaleTransition(
          scale: Tween<double>(begin: .96, end: 1).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
    );
  }

  void _showQueue(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (renderBox == null || overlay == null) return;
    final pos = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final left = (pos.dx - 420).clamp(8.0, overlay.size.width - 428);
    final top = (pos.dy - 490).clamp(8.0, overlay.size.height - 500);
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => Stack(
        children: [
          Positioned.fill(child: GestureDetector(onTap: () => Navigator.pop(context))),
          Positioned(
            left: left,
            top: top,
            child: Material(
              elevation: 16,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.surface.withOpacity(.95),
              child: Container(
                width: 420,
                height: 480,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outline.withOpacity(.15)),
                ),
                child: Column(children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('播放列表',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('${tracks.length} 首',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close, size: 18)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: tracks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (_, index) {
                        final track = tracks[index];
                        final isActive = index == _current;
                        return Container(
                          decoration: BoxDecoration(
                            color: isActive
                                ? Theme.of(context).colorScheme.surface
                                : null,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListTile(
                            dense: true,
                            leading: SizedBox(
                                width: 44,
                                height: 44,
                                child: _Art(
                                    color: track.color,
                                    size: 44,
                                    coverPath: track.coverPath)),
                            title: Text(track.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(track.artist,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Text(track.duration,
                                style: const TextStyle(fontSize: 12)),
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_playIndex(index));
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ),
      transitionBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar(
      {required this.page,
      required this.canGoBack,
      required this.onBack,
      required this.onForward,
      required this.onSettings,
      required this.unreadableCount,
      required this.scanning,
      required this.scanProgress,
      required this.onUnreadable});
  final LibraryPage page;
  final bool canGoBack;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onSettings;
  final int unreadableCount;
  final bool scanning;
  final double scanProgress;
  final VoidCallback onUnreadable;

  @override
  Widget build(BuildContext context) {
    final title = {
      LibraryPage.songs: '歌曲',
      LibraryPage.artists: '艺术家',
      LibraryPage.artistDetail: '艺术家详情',
      LibraryPage.albums: '专辑',
      LibraryPage.albumDetail: '专辑详情',
      LibraryPage.library: '音乐库',
      LibraryPage.folders: '文件夹',
      LibraryPage.folderDetail: '文件夹详情',
      LibraryPage.playlists: '歌单',
      LibraryPage.playlistDetail: '歌单详情',
      LibraryPage.stats: '库统计',
      LibraryPage.unreadable: '不可读曲目',
      LibraryPage.settings: '设置'
    }[page]!;
    return SizedBox(
        height: 48,
        child: Material(
            color: Theme.of(context).colorScheme.surface.withOpacity(.92),
            child: Stack(children: [
              const DragToMoveArea(child: SizedBox.expand()),
              Row(children: [
                const SizedBox(width: 18),
                Container(
                    width: 25,
                    height: 25,
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(7)),
                    child: const Icon(Icons.graphic_eq,
                        size: 17, color: Colors.black)),
                const SizedBox(width: 10),
                GestureDetector(
                    onDoubleTap: () async {
                      if (await windowManager.isMaximized()) {
                        await windowManager.unmaximize();
                      } else {
                        await windowManager.maximize();
                      }
                    },
                    onPanStart: (_) => windowManager.startDragging(),
                    child: const Text('Still',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, letterSpacing: .2))),
                const SizedBox(width: 28),
                IconButton(
                    tooltip: '后退',
                    onPressed: canGoBack ? onBack : null,
                    icon: const Icon(Icons.arrow_back, size: 18)),
                IconButton(
                    tooltip: '前进',
                    onPressed: onForward,
                    icon: const Icon(Icons.arrow_forward, size: 18)),
                const SizedBox(width: 8),
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (scanning)
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withOpacity(.65),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                value: scanProgress > 0 ? scanProgress : null)),
                        const SizedBox(width: 8),
                        Text('正在扫描音乐 ${(scanProgress * 100).round()}%'),
                      ]),
                    ),
                  )
                else if (unreadableCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: ActionChip(
                      avatar:
                          const Icon(Icons.warning_amber_outlined, size: 17),
                      label: Text('$unreadableCount 首无法读取'),
                      onPressed: onUnreadable,
                    ),
                  ),
                const Spacer(),
                IconButton(
                    tooltip: '设置',
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings_outlined, size: 19)),
                const SizedBox(width: 6),
                IconButton(
                    tooltip: '最小化',
                    onPressed: () => windowManager.minimize(),
                    icon: const Icon(Icons.remove, size: 18)),
                IconButton(
                    tooltip: '最大化',
                    onPressed: () async {
                      if (await windowManager.isMaximized()) {
                        await windowManager.unmaximize();
                      } else {
                        await windowManager.maximize();
                      }
                    },
                    icon: const Icon(Icons.crop_square, size: 16)),
                IconButton(
                    tooltip: '关闭',
                    onPressed: () => windowManager.close(),
                    icon: const Icon(Icons.close, size: 18)),
                const SizedBox(width: 8),
              ]),
            ])));
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(
      {required this.expanded,
      required this.page,
      required this.onSelect,
      required this.playlists,
      required this.selectedPlaylist,
      required this.onPlaylist,
      required this.onCreatePlaylist,
      required this.onToggle});
  final bool expanded;
  final LibraryPage page;
  final ValueChanged<LibraryPage> onSelect;
  final Map<String, List<Track>> playlists;
  final String? selectedPlaylist;
  final ValueChanged<String> onPlaylist;
  final VoidCallback onCreatePlaylist;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final items = [
      (LibraryPage.songs, Icons.music_note_outlined, '歌曲'),
      (LibraryPage.artists, Icons.people_outline, '艺术家'),
      (LibraryPage.albums, Icons.album_outlined, '专辑'),
      (LibraryPage.folders, Icons.folder_outlined, '文件夹'),
      (LibraryPage.library, Icons.library_music_outlined, '音乐库')
    ];
    return AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: expanded ? 256 : 64,
        color: Theme.of(context).colorScheme.surface.withOpacity(.48),
        child: Column(children: [
          const SizedBox(height: 18),
          for (final item in items)
            _NavItem(
                icon: item.$2,
                label: item.$3,
                selected: page == item.$1,
                expanded: expanded,
                onTap: () => onSelect(item.$1)),
          if (expanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 6),
              child: Row(children: [
                Expanded(
                  child: Text('我的歌单',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      )),
                ),
                IconButton(
                  tooltip: '新建歌单',
                  onPressed: onCreatePlaylist,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  icon: const Icon(Icons.add, size: 17),
                ),
              ]),
            ),
            for (final entry in playlists.entries)
              _PlaylistNavItem(
                name: entry.key,
                color: entry.value.isEmpty
                    ? Theme.of(context).colorScheme.primary
                    : entry.value.first.color,
                selected: selectedPlaylist == entry.key,
                onTap: () => onPlaylist(entry.key),
              ),
          ] else
            _NavItem(
              icon: Icons.queue_music_outlined,
              label: '歌单',
              selected: page == LibraryPage.playlists ||
                  page == LibraryPage.playlistDetail,
              expanded: expanded,
              onTap: () => onSelect(LibraryPage.playlists),
            ),
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Divider(height: 1)),
          _NavItem(
              icon: Icons.bar_chart_outlined,
              label: '库统计',
              selected: page == LibraryPage.stats,
              expanded: expanded,
              onTap: () => onSelect(LibraryPage.stats)),
          _NavItem(
              icon: Icons.settings_outlined,
              label: '设置',
              selected: page == LibraryPage.settings,
              expanded: expanded,
              onTap: () => onSelect(LibraryPage.settings)),
          const Spacer(),
          _NavItem(
              icon: expanded
                  ? Icons.keyboard_double_arrow_left
                  : Icons.keyboard_double_arrow_right,
              label: '收起侧栏',
              selected: false,
              expanded: expanded,
              onTap: onToggle),
          const SizedBox(height: 14),
        ]));
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.expanded,
      required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Tooltip(
          message: label,
          child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                  height: 42,
                  decoration: BoxDecoration(
                      color: selected
                          ? Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(.14)
                          : null,
                      borderRadius: BorderRadius.circular(8)),
                  child: Stack(children: [
                    if (!expanded && selected)
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 3,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    AnimatedAlign(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      alignment:
                          expanded ? Alignment.centerLeft : Alignment.center,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SizeTransition(
                            sizeFactor: animation,
                            axis: Axis.horizontal,
                            child: child,
                          ),
                        ),
                        child: expanded
                            ? Row(
                                key: const ValueKey('expanded'),
                                children: [
                                  AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 180),
                                      width: selected ? 3 : 0,
                                      margin: EdgeInsets.only(
                                          right: selected ? 11 : 14),
                                      decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          borderRadius:
                                              BorderRadius.circular(3))),
                                  Icon(icon,
                                      size: 20,
                                      color: selected
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant),
                                  const SizedBox(width: 14),
                                  Flexible(
                                      child: Text(label,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600))),
                                ],
                              )
                            : Icon(
                                icon,
                                key: const ValueKey('collapsed'),
                                size: 20,
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                              ),
                      ),
                    ),
                  ])))));
}

class _PlaylistNavItem extends StatelessWidget {
  const _PlaylistNavItem({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primary.withOpacity(.12)
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              _Art(color: color, size: 30),
              const SizedBox(width: 6),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      );
}

class _SortDropdown extends StatelessWidget {
  const _SortDropdown({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  static const _options = [
    '手动',
    '添加时间',
    '标题 A-Z',
    '标题 Z-A',
    '艺术家',
    '专辑',
    '年份',
    '时长',
    '文件名',
  ];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final renderBox = context.findRenderObject() as RenderBox?;
        final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
        if (renderBox == null || overlay == null) return;
        final pos = renderBox.localToGlobal(
          Offset.zero,
          ancestor: overlay,
        );
        showMenu<String>(
          context: context,
          position: RelativeRect.fromLTRB(
              pos.dx, pos.dy + renderBox.size.height + 4, pos.dx + renderBox.size.width, 0),
          elevation: 8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          items: [
            for (final option in _options)
              PopupMenuItem<String>(
                value: option,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(option, style: const TextStyle(fontSize: 13)),
                    if (option == value)
                      Icon(Icons.check,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                  ],
                ),
              ),
          ],
        ).then((v) {
          if (v != null) onChanged(v);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('排序：$value',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

String _totalDuration(List<Track> tracks) {
  int totalSeconds = 0;
  for (final t in tracks) {
    final parts = t.duration.split(':');
    if (parts.length == 2) {
      final min = int.tryParse(parts[0]) ?? 0;
      final sec = int.tryParse(parts[1]) ?? 0;
      totalSeconds += min * 60 + sec;
    }
  }
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  if (h > 0) return '$h 小时 $m 分钟';
  return '$m 分钟';
}

class SongsPage extends StatelessWidget {
  const SongsPage(
      {super.key,
      required this.query,
      required this.sort,
      required this.grid,
      required this.playing,
      required this.current,
      this.locatedTrackIndex,
      required this.onQuery,
      required this.onSort,
      required this.onGrid,
      required this.onPlay,
      required this.onArtist,
      required this.onAlbum,
      this.selectionMode = false,
      this.selectedTracks = const <Track>{},
      this.onToggleSelection,
      this.onToggleSelectionMode,
      this.onSelectAll,
      this.onAddSelectedToPlaylist,
      this.onDeleteSelected,
      this.lastTappedIndex,
      this.onRangeSelect,
      this.playlists,
      this.onBatchContext});
  final String query, sort;
  final bool grid, playing;
  final int current;
  final int? locatedTrackIndex;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onSort;
  final VoidCallback onGrid;
  final ValueChanged<int> onPlay;
  final ValueChanged<String> onArtist, onAlbum;
  final bool selectionMode;
  final Set<Track> selectedTracks;
  final ValueChanged<Track>? onToggleSelection;
  final VoidCallback? onToggleSelectionMode;
  final VoidCallback? onSelectAll;
  final VoidCallback? onAddSelectedToPlaylist;
  final VoidCallback? onDeleteSelected;
  final int? lastTappedIndex;
  final void Function(int tappedIndex, bool shiftHeld)? onRangeSelect;
  final Map<String, List<Track>>? playlists;
  final VoidCallback? onBatchContext;
  @override
  Widget build(BuildContext context) {
    final shown = tracks
        .where((t) =>
            PinyinUtils.matches(query, [t.title, t.artist, t.album, t.title]))
        .toList();
    shown.sort((a, b) {
      switch (sort) {
        case '标题 A-Z':
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case '标题 Z-A':
          return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case '艺术家':
          return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        case '专辑':
          return a.album.toLowerCase().compareTo(b.album.toLowerCase());
        case '时长':
          return a.duration.compareTo(b.duration);
        case '文件名':
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        default:
          return 0;
      }
    });
    final sections = <String, List<Track>>{};
    for (final track in shown) {
      final initials = PinyinUtils.index(track.title).initials.toUpperCase();
      final letter =
          initials.isNotEmpty && RegExp(r'^[A-Z]$').hasMatch(initials[0])
              ? initials[0]
              : '#';
      (sections[letter] ??= <Track>[]).add(track);
    }
    final sectionKeys = sections.keys.toList()
      ..sort((a, b) => a == '#'
          ? -1
          : b == '#'
              ? 1
              : a.compareTo(b));
    return Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('歌曲',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('${tracks.length} 首歌曲 · ${_totalDuration(tracks)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant))
            ]),
            const Spacer(),
            IconButton.filledTonal(
                tooltip: selectionMode ? '退出多选' : '多选歌曲',
                onPressed: onToggleSelectionMode,
                icon: Icon(selectionMode ? Icons.close : Icons.checklist)),
            const SizedBox(width: 8),
            FilledButton.icon(
                onPressed: () => onPlay(0),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('全部播放')),
            const SizedBox(width: 9),
            OutlinedButton.icon(
                onPressed: () => onPlay(
                    DateTime.now().millisecondsSinceEpoch % tracks.length),
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('随机播放'))
          ]),
          const SizedBox(height: 22),
          if (selectionMode) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.check_circle,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('已选择 ${selectedTracks.length} 首歌曲',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer)),
                const Spacer(),
                if (onSelectAll != null)
                  TextButton.icon(
                      onPressed: onSelectAll,
                      icon: const Icon(Icons.select_all, size: 18),
                      label: const Text('全选')),
                if (onAddSelectedToPlaylist != null) ...[
                  const SizedBox(width: 4),
                  TextButton.icon(
                      onPressed: onAddSelectedToPlaylist,
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: const Text('添加到歌单')),
                ],
                if (onDeleteSelected != null) ...[
                  const SizedBox(width: 4),
                  TextButton.icon(
                      onPressed: onDeleteSelected,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除')),
                ],
                const SizedBox(width: 4),
                TextButton.icon(
                    onPressed: onToggleSelectionMode,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('退出')),
              ]),
            ),
            const SizedBox(height: 10),
          ],
          Row(children: [
            _SortDropdown(
                value: sort,
                onChanged: onSort),
            const SizedBox(width: 12),
            IconButton.filledTonal(
                tooltip: '切换视图',
                onPressed: onGrid,
                icon: Icon(grid ? Icons.view_list : Icons.grid_view)),
            const SizedBox(width: 8),
            Text('${shown.length} 首',
                style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            SizedBox(
                width: 320,
                height: 36,
                child: TextField(
                    onChanged: onQuery,
                    decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search, size: 18),
                        hintText: '筛选当前列表',
                        contentPadding: EdgeInsets.zero,
                        border: const OutlineInputBorder())))
          ]),
          const SizedBox(height: 10),
          if (!grid) ...[
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                if (selectionMode) const SizedBox(width: 36),
                const SizedBox(width: 56 + 12),
                Expanded(
                    flex: 13,
                    child: Text('歌曲',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))),
                Expanded(
                    flex: 10,
                    child: Text('专辑',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))),
                SizedBox(
                    width: 74,
                    child: Text('年份',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))),
                SizedBox(
                    width: 68,
                    child: Text('时长',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))),
              ]),
            ),
            const SizedBox(height: 4),
          ],
          Expanded(
            child: Stack(children: [
              grid
                  ? _TrackGrid(
                      tracks: shown,
                      onPlay: onPlay,
                      onArtist: onArtist,
                      onAlbum: onAlbum,
                    )
                  : ListView(children: [
                      for (final letter in sectionKeys) ...[
                        Container(
                            margin: const EdgeInsets.fromLTRB(0, 14, 0, 6),
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surface
                                  .withOpacity(.92),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(letter,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w900)),
                            )),
                        for (final t in sections[letter]!) ...[
                          _TrackRow(
                            track: t,
                            index: tracks.indexOf(t),
                            selected: playing && tracks.indexOf(t) == current,
                            located: locatedTrackIndex == tracks.indexOf(t),
                            selectionMode: selectionMode,
                            checked: selectedTracks.contains(t),
                            onToggleSelection: onToggleSelection == null
                                ? null
                                : () => onToggleSelection!(t),
                            onPlay: () => onPlay(tracks.indexOf(t)),
                            onArtist: () => onArtist(t.artist),
                            onAlbum: () => onAlbum(t.album),
                            onInfo: () => _showTrackContextMenu(
                                context, t, onArtist, onAlbum,
                                playlists: playlists),
                            onRangeSelect: onRangeSelect == null
                                ? null
                                : (shift) => onRangeSelect!(
                                    tracks.indexOf(t), shift),
                            onBatchContext: onBatchContext,
                          ),
                          const SizedBox(height: 3),
                        ],
                      ],
                    ]),
              if (!grid)
                Positioned(
                  top: 8,
                  right: 0,
                  bottom: 8,
                  child: _AlphabetRail(onLetter: (letter) {
                    final controller = PrimaryScrollController.of(context);
                    if (!controller.hasClients) return;
                    final ratio =
                        letter == '#' ? 0.0 : (letter.codeUnitAt(0) - 65) / 26;
                    controller.animateTo(
                      controller.position.maxScrollExtent *
                          ratio.clamp(0.0, 1.0),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                    );
                  }),
                ),
            ]),
          ),
        ]));
  }
}

class _AlphabetRail extends StatelessWidget {
  const _AlphabetRail({required this.onLetter});
  final ValueChanged<String> onLetter;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => _showAlphabetGrid(context),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withOpacity(.82),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final letter in [
                  '#',
                  ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')
                ])
                  SizedBox(
                    width: 20,
                    height: 18,
                    child: Center(
                      child: Text(letter,
                          style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

  void _showAlphabetGrid(BuildContext context) {
    final letters = ['#', ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')];
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => Stack(
        children: [
          Positioned.fill(
              child: GestureDetector(onTap: () => Navigator.pop(context))),
          Center(
            child: Material(
              elevation: 16,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.surface.withOpacity(.95),
              child: Container(
                width: 420,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withOpacity(.15)),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final letter in letters)
                      InkWell(
                        onTap: () {
                          Navigator.pop(context);
                          onLetter(letter);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 50,
                          height: 44,
                          child: Center(
                            child: Text(letter,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      transitionBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: .95, end: 1).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        ),
      ),
    );
  }
}

class _TrackRow extends StatefulWidget {
  const _TrackRow(
      {super.key,
      required this.track,
      required this.index,
      required this.selected,
      required this.onPlay,
      required this.onInfo,
      required this.onArtist,
      required this.onAlbum,
      this.selectionMode = false,
      this.checked = false,
      this.located = false,
      this.onToggleSelection,
      this.onRangeSelect,
      this.onBatchContext});
  final Track track;
  final int index;
  final bool selected;
  final VoidCallback onPlay, onInfo, onArtist, onAlbum;
  final bool selectionMode, checked, located;
  final VoidCallback? onToggleSelection;
  final ValueChanged<bool>? onRangeSelect;
  final VoidCallback? onBatchContext;
  @override
  State<_TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<_TrackRow> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final shiftHeld =
        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);
    final ctrlHeld =
        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.controlLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.controlRight);
    return MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: InkWell(
          onDoubleTap: widget.onPlay,
          onTap: widget.selectionMode
              ? () {
                  if (shiftHeld || ctrlHeld) {
                    widget.onRangeSelect?.call(shiftHeld);
                  } else {
                    widget.onToggleSelection?.call();
                  }
                }
              : widget.onPlay,
          onSecondaryTap: widget.selectionMode
              ? widget.onBatchContext
              : widget.onInfo,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: widget.selected
                  ? Theme.of(context).colorScheme.primary.withOpacity(.12)
                  : hover
                      ? Theme.of(context).colorScheme.surface.withOpacity(.75)
                      : null,
              borderRadius: BorderRadius.circular(12),
              border: widget.located && !widget.selectionMode
                  ? Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(.6),
                      width: 2)
                  : null,
            ),
            child: Row(children: [
              if (widget.selectionMode)
                SizedBox(
                  width: 36,
                  child: Checkbox(
                      value: widget.checked,
                      onChanged: (_) => widget.onToggleSelection?.call()),
                ),
              _Art(
                  color: widget.track.color,
                  size: 56,
                  coverPath: widget.track.coverPath),
              const SizedBox(width: 12),
              Expanded(
                  flex: 13,
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 3),
                    Row(children: [
                      Flexible(
                        child: InkWell(
                          onTap: () => widget.onArtist(),
                          child: Text(widget.track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text('·',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                      ),
                      Flexible(
                        child: InkWell(
                          onTap: () => widget.onAlbum(),
                          child: Text(widget.track.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                        ),
                      ),
                    ]),
                  ])),
              Expanded(
                  flex: 10,
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(widget.track.album,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)))),
              SizedBox(
                  width: 74,
                  child: Text(widget.track.year,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ]))),
              SizedBox(
                  width: 68,
                  child: Text(widget.track.duration,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ]))),
            ]),
          ),
        ),
      );
}
}

class _TrackList extends StatelessWidget {
  const _TrackList({
    required this.songs,
    required this.onPlay,
    this.onArtist,
    this.onAlbum,
    this.onRemove,
    this.onRelink,
    this.reorderable = false,
    this.onReorder,
  });

  final List<Track> songs;
  final ValueChanged<Track> onPlay;
  final ValueChanged<String>? onArtist;
  final ValueChanged<String>? onAlbum;
  final ValueChanged<Track>? onRemove;
  final ValueChanged<Track>? onRelink;
  final bool reorderable;
  final void Function(int, int)? onReorder;

  @override
  Widget build(BuildContext context) {
    if (reorderable) {
      return ReorderableListView.builder(
        itemCount: songs.length,
        onReorder: onReorder ?? (_, __) {},
        itemBuilder: (context, index) => _row(context, songs[index], index),
      );
    }
    return ListView.separated(
      itemCount: songs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 3),
      itemBuilder: (context, index) => _row(context, songs[index], index),
    );
  }

  Widget _row(BuildContext context, Track track, int index) {
    return _TrackRow(
      key: reorderable ? ValueKey('${track.path}-$index') : null,
      track: track,
      index: index,
      selected: false,
      onPlay: () => onPlay(track),
      onArtist: () => onArtist?.call(track.artist),
      onAlbum: () => onAlbum?.call(track.album),
      onInfo: () => _showTrackContextMenu(
          context, track, onArtist, onAlbum,
          onRemove: onRemove, onRelink: onRelink),
    );
  }
}

class _ContextMenuEntry {
  const _ContextMenuEntry.item(this.label, {this.onTap, this.shortcut, this.destructive = false, this.accent = false})
      : isSeparator = false;
  const _ContextMenuEntry.separator()
      : isSeparator = true, label = null, onTap = null, shortcut = null, destructive = false, accent = false;
  final bool isSeparator;
  final String? label;
  final VoidCallback? onTap;
  final String? shortcut;
  final bool destructive;
  final bool accent;
}

void _showTrackContextMenu(BuildContext context, Track track,
    ValueChanged<String>? onArtist, ValueChanged<String>? onAlbum,
    {ValueChanged<Track>? onRemove, ValueChanged<Track>? onRelink,
    Map<String, List<Track>>? playlists, ValueChanged<Track>? onDelete,
    VoidCallback? onPlay, VoidCallback? onPlayNext, VoidCallback? onAddQueue,
    String? playlistId, VoidCallback? onRemoveFromPlaylist}) {
  final entries = <_ContextMenuEntry>[
    _ContextMenuEntry.item('专辑：${track.album}', onTap: () {
      Navigator.pop(context);
      onAlbum?.call(track.album);
    }),
    _ContextMenuEntry.item('艺术家：${track.artist}', onTap: () {
      Navigator.pop(context);
      onArtist?.call(track.artist);
    }),
    const _ContextMenuEntry.separator(),
    if (playlists != null && playlists.isNotEmpty)
      _ContextMenuEntry.item('添加到歌单', onTap: () {
        Navigator.pop(context);
        _showPlaylistSubmenu(context, playlists, (name, t) {
          if (!playlists[name]!.contains(t)) {
            playlists[name]!.add(t);
          }
        }, track);
      }),
    if (onPlay != null)
      _ContextMenuEntry.item('插播（当前播放后）', onTap: () {
        Navigator.pop(context);
        onPlay();
      }, shortcut: 'Ctrl+Enter'),
    if (onPlayNext != null)
      _ContextMenuEntry.item('插播（上次插播后）', onTap: () {
        Navigator.pop(context);
        onPlayNext();
      }, shortcut: 'Shift+Enter'),
    if (onAddQueue != null)
      _ContextMenuEntry.item('插播（队列末尾）', onTap: () {
        Navigator.pop(context);
        onAddQueue();
      }, shortcut: 'Alt+Enter'),
    const _ContextMenuEntry.separator(),
    _ContextMenuEntry.item('复制文件地址', onTap: () {
      Navigator.pop(context);
      Clipboard.setData(ClipboardData(text: track.path));
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制路径'), duration: Duration(seconds: 1)));
    }, shortcut: 'Ctrl+C'),
    _ContextMenuEntry.item('音轨信息', onTap: () {
      Navigator.pop(context);
      showDialog<void>(
          context: context, builder: (_) => TrackInfoDialog(track: track));
    }, shortcut: 'Alt+I'),
    const _ContextMenuEntry.separator(),
    if (playlistId != null && onRemoveFromPlaylist != null)
      _ContextMenuEntry.item('从当前歌单移除', onTap: () {
        Navigator.pop(context);
        onRemoveFromPlaylist();
      }, accent: true),
    if (onDelete != null)
      _ContextMenuEntry.item('从音乐库中移除', onTap: () {
        Navigator.pop(context);
        showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
                    title: const Text('删除歌曲'),
                    content: Text('确定删除「${track.title}」？\n此操作不会删除实际文件。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('删除')),
                    ])).then((ok) {
          if (ok == true) onDelete(track);
        });
      }, destructive: true),
  ];
  _showContextMenu(context, header: track.title, entries: entries);
}

void _showBatchContextMenu(BuildContext context, Set<Track> selected,
    {Map<String, List<Track>>? playlists, VoidCallback? onDelete,
    VoidCallback? onClearSelection, String? playlistId,
    VoidCallback? onRemoveFromPlaylist}) {
  final count = selected.length;
  final entries = <_ContextMenuEntry>[
    if (playlists != null && playlists.isNotEmpty)
      _ContextMenuEntry.item('添加到歌单', onTap: () {
        Navigator.pop(context);
        _showPlaylistSubmenu(context, playlists, (name, t) {
          if (!playlists[name]!.contains(t)) {
            playlists[name]!.add(t);
          }
        }, null, selected: selected);
      }),
    _ContextMenuEntry.item('插播（当前播放后）', onTap: () {
      Navigator.pop(context);
    }, shortcut: 'Ctrl+Enter'),
    _ContextMenuEntry.item('插播（上次插播后）', onTap: () {
      Navigator.pop(context);
    }, shortcut: 'Shift+Enter'),
    _ContextMenuEntry.item('插播（队列末尾）', onTap: () {
      Navigator.pop(context);
    }, shortcut: 'Alt+Enter'),
    const _ContextMenuEntry.separator(),
    _ContextMenuEntry.item('复制文件地址', onTap: () {
      Navigator.pop(context);
      final paths = selected.map((t) => t.path).join('\n');
      Clipboard.setData(ClipboardData(text: paths));
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已复制 $count 个文件路径'), duration: const Duration(seconds: 1)));
    }, shortcut: 'Ctrl+C'),
    const _ContextMenuEntry.separator(),
    if (playlistId != null && onRemoveFromPlaylist != null)
      _ContextMenuEntry.item('从当前歌单移除', onTap: () {
        Navigator.pop(context);
        onRemoveFromPlaylist();
      }, accent: true),
    if (onDelete != null)
      _ContextMenuEntry.item('从音乐库中移除', onTap: () {
        Navigator.pop(context);
        showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
                    title: const Text('删除歌曲'),
                    content: Text('确定从库中删除选中的 $count 首歌曲？\n此操作不会删除实际文件。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('删除')),
                    ])).then((ok) {
          if (ok == true) onDelete();
        });
      }, destructive: true),
    if (onClearSelection != null)
      _ContextMenuEntry.item('取消全选', onTap: () {
        Navigator.pop(context);
        onClearSelection();
      }),
  ];
  _showContextMenu(context, header: '已选 $count 首歌曲', entries: entries);
}

void _showPlaylistSubmenu(BuildContext context, Map<String, List<Track>> playlists,
    void Function(String name, Track track) onAdd, Track? singleTrack,
    {Set<Track>? selected}) {
  final names = playlists.keys.toList();
  final count = singleTrack != null ? 1 : (selected?.length ?? 0);
  showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
              title: Text(singleTrack != null ? '添加到歌单' : '添加 $count 首歌曲到歌单'),
              content: SizedBox(
                width: 280,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: names.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(names[i]),
                    subtitle: Text('${playlists[names[i]]!.length} 首歌曲'),
                    onTap: () {
                      Navigator.pop(context);
                      if (singleTrack != null) {
                        onAdd(names[i], singleTrack);
                      } else if (selected != null) {
                        for (final t in selected) {
                          onAdd(names[i], t);
                        }
                      }
                    },
                  ),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
              ]));
}

void _showContextMenu(BuildContext context, {required String header, required List<_ContextMenuEntry> entries}) {
  final renderBox = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (renderBox == null || overlay == null) return;
  final pos = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
  final left = pos.dx.clamp(8.0, overlay.size.width - 336);
  final top = (pos.dy + renderBox.size.height).clamp(8.0, overlay.size.height - 520);
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (_, __, ___) => Stack(
      children: [
        Positioned.fill(child: GestureDetector(onTap: () => Navigator.pop(context))),
        Positioned(
          left: left,
          top: top,
          child: Material(
            elevation: 16,
            borderRadius: BorderRadius.circular(16),
            color: Theme.of(context).colorScheme.surface.withOpacity(.95),
            child: Container(
              width: 320,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outline.withOpacity(.12)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(header,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                  ),
                  for (var i = 0; i < entries.length; i++) ...[
                    if (entries[i].isSeparator)
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                        height: 1,
                        color: Theme.of(context).colorScheme.outline.withOpacity(.12),
                      )
                    else
                      InkWell(
                        onTap: entries[i].onTap,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(children: [
                            Expanded(
                                child: Text(entries[i].label!,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: entries[i].destructive
                                            ? Theme.of(context).colorScheme.error
                                            : entries[i].accent
                                                ? Theme.of(context).colorScheme.primary
                                                : null))),
                            if (entries[i].shortcut != null) ...[
                              const SizedBox(width: 8),
                              Text(entries[i].shortcut!,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                            ],
                          ]),
                        ),
                      ),
                  ],
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
    transitionBuilder: (_, animation, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween<double>(begin: .98, end: 1).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );
}

class _TrackGrid extends StatelessWidget {
  const _TrackGrid(
      {required this.tracks,
      required this.onPlay,
      required this.onArtist,
      required this.onAlbum});
  final List<Track> tracks;
  final ValueChanged<int> onPlay;
  final ValueChanged<String> onArtist, onAlbum;
  @override
  Widget build(BuildContext context) => GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisExtent: 216,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
        ),
        itemCount: tracks.length,
        itemBuilder: (_, i) {
          final t = tracks[i];
          return InkWell(
            onTap: () => onPlay(tracks.indexOf(t)),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Art(color: t.color, size: 148, coverPath: t.coverPath),
                    const SizedBox(height: 9),
                    Text(t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Row(children: [
                      Flexible(
                        child: InkWell(
                          onTap: () => onArtist(t.artist),
                          child: Text(t.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text('·'),
                      ),
                      Flexible(
                        child: InkWell(
                          onTap: () => onAlbum(t.album),
                          child: Text(t.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                        ),
                      ),
                    ]),
                  ]),
            ),
          );
        },
      );
}

class _Art extends StatelessWidget {
  const _Art({required this.color, this.size = 56, this.coverPath = ''});
  final Color color;
  final double size;
  final String coverPath;
  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(size > 60 ? 12 : 8);
    if (coverPath.isNotEmpty) {
      return Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: borderRadius),
        child: Image.file(
          File(coverPath),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildFallback(),
        ),
      );
    }
    return _buildFallback();
  }

  Widget _buildFallback() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(size > 60 ? 12 : 8)),
      child: Icon(Icons.music_note,
          color: Colors.white.withOpacity(.76), size: size * .42));
}

class _PlaybackBar extends StatelessWidget {
  const _PlaybackBar(
      {required this.track,
      required this.playing,
      required this.mode,
      required this.volume,
      required this.speed,
      required this.desktopLyricsVisible,
      required this.onPlay,
      required this.onPrevious,
      required this.onNext,
      required this.onStop,
      required this.onVolume,
      required this.muted,
      required this.onMute,
      required this.onMode,
      required this.position,
      required this.onSeek,
      required this.onLyrics,
      required this.onDesktopLyrics,
      required this.onSpeed,
      required this.onPlaylist});
  final Track track;
  final bool playing, muted, desktopLyricsVisible;
  final PlaybackMode mode;
  final Duration position;
  final double volume, speed;
  final VoidCallback onPlay,
      onPrevious,
      onNext,
      onStop,
      onLyrics,
      onMute,
      onMode,
      onDesktopLyrics,
      onPlaylist;
  final ValueChanged<double> onVolume, onSpeed;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final modeLabel = switch (mode) {
      PlaybackMode.sequential => '顺序播放',
      PlaybackMode.playlistLoop => '循环播放',
      PlaybackMode.singleTrackLoop => '单曲循环',
      PlaybackMode.shuffle => '随机播放',
    };
    final modeIcon = switch (mode) {
      PlaybackMode.sequential => Icons.format_list_bulleted,
      PlaybackMode.playlistLoop => Icons.repeat,
      PlaybackMode.singleTrackLoop => Icons.repeat_one,
      PlaybackMode.shuffle => Icons.shuffle,
    };
    final duration = _durationMilliseconds(track.duration);
    final progress =
        (position.inMilliseconds / duration).clamp(0, 1).toDouble();
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: 96,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withOpacity(.94),
            border: Border(
                top: BorderSide(
                    color: Theme.of(context).dividerColor.withOpacity(.45))),
          ),
          child: Stack(children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: Theme.of(context).colorScheme.primary,
                  inactiveTrackColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  thumbColor: Theme.of(context).colorScheme.primary,
                ),
                child: Slider(
                  value: progress,
                  min: 0,
                  max: 1,
                  onChanged: (value) => onSeek(
                      Duration(milliseconds: (duration * value).round())),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(children: [
                Expanded(
                  flex: 3,
                  child: Row(children: [
                    GestureDetector(
                      onTap: onLyrics,
                      child: Hero(
                          tag: 'active-cover',
                          child: _Art(
                              color: track.color,
                              size: 52,
                              coverPath: track.coverPath)),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                        child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                      ],
                    )),
                  ]),
                ),
                Expanded(
                  flex: 5,
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_formatDuration(position),
                            style: Theme.of(context).textTheme.labelSmall),
                        const SizedBox(width: 8),
                        IconButton(
                            tooltip: modeLabel,
                            onPressed: onMode,
                            icon: Icon(modeIcon,
                                size: 19,
                                color: mode == PlaybackMode.sequential
                                    ? null
                                    : Theme.of(context).colorScheme.primary)),
                        IconButton(
                            tooltip: '上一首',
                            onPressed: onPrevious,
                            icon: const Icon(Icons.skip_previous, size: 23)),
                        IconButton.filled(
                            tooltip: playing ? '暂停' : '播放',
                            onPressed: onPlay,
                            icon: Icon(playing ? Icons.pause : Icons.play_arrow,
                                size: 22)),
                        IconButton(
                            tooltip: '下一首',
                            onPressed: onNext,
                            icon: const Icon(Icons.skip_next, size: 23)),
                        IconButton(
                            tooltip: '停止',
                            onPressed: onStop,
                            icon: const Icon(Icons.stop, size: 20)),
                        const SizedBox(width: 8),
                        Text(track.duration,
                            style: Theme.of(context).textTheme.labelSmall),
                      ]),
                ),
                Expanded(
                  flex: 3,
                  child:
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    IconButton(
                        tooltip: '桌面歌词',
                        onPressed: onDesktopLyrics,
                        icon: Icon(Icons.subtitles_outlined,
                            size: 20,
                            color: desktopLyricsVisible
                                ? Theme.of(context).colorScheme.primary
                                : null)),
                    IconButton(
                        tooltip: '倍速',
                        onPressed: () => _speedDialog(context),
                        icon: Text('${speed.toStringAsFixed(2)}x',
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700))),
                    IconButton(
                        tooltip: '音量',
                        onPressed: () => _volumeDialog(context),
                        icon: Icon(
                            muted || volume == 0
                                ? Icons.volume_off
                                : Icons.volume_up,
                            size: 20)),
                    IconButton(
                        tooltip: '播放列表',
                        onPressed: onPlaylist,
                        icon: const Icon(Icons.queue_music, size: 20)),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  void _volumeDialog(BuildContext context) {
    var dialogVolume = volume;
    var dialogMuted = muted;
    final renderBox = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (renderBox == null || overlay == null) return;
    final pos = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final left = (pos.dx + renderBox.size.width - 320).clamp(0.0, overlay.size.width - 320);
    final top = pos.dy - 80;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => Stack(
        children: [
          Positioned.fill(child: GestureDetector(onTap: () => Navigator.pop(context))),
          Positioned(
            left: left,
            top: top,
            child: Material(
              elevation: 16,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.surface.withOpacity(.95),
              child: StatefulBuilder(
                builder: (context, setDialogState) => Container(
                  width: 320,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outline.withOpacity(.15)),
                  ),
                  child: Row(children: [
                    IconButton(
                        tooltip: dialogMuted ? '取消静音' : '静音',
                        onPressed: () {
                          onMute();
                          dialogMuted = !dialogMuted;
                          setDialogState(() {});
                        },
                        icon: Icon(dialogMuted ? Icons.volume_off : Icons.volume_up)),
                    Expanded(
                        child: Slider(
                            value: dialogVolume,
                            min: 0,
                            max: 1,
                            divisions: 100,
                            label: '${(dialogVolume * 100).round()}%',
                            onChanged: (value) {
                              dialogVolume = value;
                              onVolume(value);
                              setDialogState(() {});
                            })),
                    SizedBox(
                        width: 48,
                        child: Text('${(dialogVolume * 100).round()}%',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20))),
                  ]),
                ),
              ),
            ),
          ),
        ],
      ),
      transitionBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );
  }

  void _speedDialog(BuildContext context) {
    const presets = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    var dialogSpeed = speed;
    final renderBox = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (renderBox == null || overlay == null) return;
    final pos = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final left = (pos.dx + renderBox.size.width - 560).clamp(0.0, overlay.size.width - 560);
    final top = pos.dy - 120;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => Stack(
        children: [
          Positioned.fill(child: GestureDetector(onTap: () => Navigator.pop(context))),
          Positioned(
            left: left,
            top: top,
            child: Material(
              elevation: 16,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.surface.withOpacity(.95),
              child: StatefulBuilder(
                builder: (context, setDialogState) => Container(
                  width: 560,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outline.withOpacity(.15)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Slider(
                                value: dialogSpeed,
                                min: .5,
                                max: 2,
                                divisions: 30,
                                label: '${dialogSpeed.toStringAsFixed(2)}x',
                                onChanged: (value) {
                                  dialogSpeed = value;
                                  onSpeed(value);
                                  setDialogState(() {});
                                })),
                        SizedBox(
                            width: 54,
                            child: Text('${dialogSpeed.toStringAsFixed(2)}x',
                                textAlign: TextAlign.right,
                                style: const TextStyle(fontWeight: FontWeight.w700))),
                      ]),
                      const SizedBox(height: 8),
                      Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final preset in presets)
                              ChoiceChip(
                                  label: Text('${preset}x'),
                                  selected: (dialogSpeed - preset).abs() < .01,
                                  onSelected: (_) {
                                    dialogSpeed = preset;
                                    onSpeed(preset);
                                    setDialogState(() {});
                                  })
                          ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      transitionBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );
  }

  static int _durationMilliseconds(String value) {
    final parts = value.split(':').map(int.tryParse).toList();
    if (parts.length == 2 && parts[0] != null && parts[1] != null) {
      return (parts[0]! * 60 + parts[1]!) * 1000;
    }
    return 1;
  }

  static String _formatDuration(Duration value) =>
      '${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}

class _CollectionCardHover extends StatefulWidget {
  const _CollectionCardHover({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;
  @override
  State<_CollectionCardHover> createState() => _CollectionCardHoverState();
}

class _CollectionCardHoverState extends State<_CollectionCardHover> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: hover
                  ? Theme.of(context).colorScheme.surface
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: widget.child,
          ),
        ),
      );
}

class CollectionPage extends StatelessWidget {
  const CollectionPage(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.icon,
      required this.labels,
      this.counts,
      required this.onTap});
  final String title, subtitle;
  final IconData icon;
  final List<String> labels;
  final List<String>? counts;
  final ValueChanged<String> onTap;
  @override
  Widget build(BuildContext context) {
    final isArtist = title == '艺术家';
    return Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 22),
          Expanded(
              child: GridView.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: isArtist ? 360 : 230,
              mainAxisExtent: isArtist ? 112 : 260,
              crossAxisSpacing: 20,
              mainAxisSpacing: 24,
            ),
            itemCount: labels.length,
            itemBuilder: (_, i) => _CollectionCardHover(
              onTap: () => onTap(labels[i]),
              child: isArtist
                  ? Container(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        _Art(
                            color: Colors
                                .primaries[i % Colors.primaries.length]
                                .withOpacity(.72),
                            size: 64),
                        const SizedBox(width: 16),
                        Expanded(
                            child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(labels[i],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text(counts != null && i < counts!.length
                                  ? counts![i]
                                  : '${(i + 2) * 3} 首歌曲',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ])),
                      ]),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Expanded(
                          child: _Art(
                              color: Colors
                                  .primaries[i % Colors.primaries.length]
                                  .withOpacity(.72),
                              size: 260),
                        ),
                        const SizedBox(height: 8),
                        Text(labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(
                            counts != null && i < counts!.length
                                ? counts![i]
                                : '${(i + 2) * 3} 首歌曲',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                      ]),
            ),
          )),
        ]));
  }
}

class MusicLibraryPage extends StatelessWidget {
  const MusicLibraryPage(
      {super.key,
      required this.folders,
      required this.onAdd,
      required this.onRefresh,
      required this.unreadableCount,
      required this.onUnreadable});
  final List<String> folders;
  final VoidCallback onAdd;
  final VoidCallback onRefresh;
  final int unreadableCount;
  final VoidCallback onUnreadable;
  @override
  Widget build(BuildContext context) {
    final artistCount = tracks.map((track) => track.artist).toSet().length;
    final albumCount = tracks.map((track) => track.album).toSet().length;
    final duration = tracks.fold<int>(
        0, (total, track) => total + _durationSeconds(track.duration));
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: ListView(children: [
        Row(children: [
          Text('音乐库',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 14),
          Text('${tracks.length}',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const Spacer(),
          FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('添加文件夹')),
        ]),
        const SizedBox(height: 28),
        InkWell(
          onTap: onAdd,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 156,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  style: BorderStyle.solid),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.file_download_outlined,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 10),
              Text('拖放文件或文件夹到此处可自动识别',
                  style: Theme.of(context).textTheme.titleMedium),
            ]),
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Wrap(spacing: 48, runSpacing: 18, children: [
            _LibraryMetric(label: '歌曲', value: '${tracks.length}'),
            _LibraryMetric(label: '艺术家', value: '$artistCount'),
            _LibraryMetric(label: '专辑', value: '$albumCount'),
            _LibraryMetric(label: '文件夹', value: '${folders.length}'),
            _LibraryMetric(
                label: '总时长',
                value:
                    '${(duration ~/ 3600).toString().padLeft(2, '0')}:${((duration ~/ 60) % 60).toString().padLeft(2, '0')}'),
            TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新音乐库'),
            ),
          ]),
        ),
        if (unreadableCount > 0) ...[
          const SizedBox(height: 14),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            tileColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            leading: const Icon(Icons.warning_amber_outlined),
            title: const Text('无法读取的音轨'),
            trailing: Text('$unreadableCount'),
            onTap: onUnreadable,
          ),
        ],
      ]),
    );
  }
}

class _LibraryMetric extends StatelessWidget {
  const _LibraryMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 116,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ]),
      );
}

class FoldersPage extends StatelessWidget {
  const FoldersPage(
      {super.key,
      required this.folders,
      required this.songs,
      required this.onOpen});
  final List<String> folders;
  final List<Track> songs;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('文件夹',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 14),
            Text('${folders.length}',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 24),
          Expanded(
            child: folders.isEmpty
                ? Center(
                    child: Text('还没有已扫描的文件夹',
                        style: Theme.of(context).textTheme.bodyLarge))
                : ListView.separated(
                    itemCount: folders.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, index) {
                      final path = folders[index];
                      final total = songs
                          .where((track) => track.path.startsWith(path))
                          .length;
                      return FolderTile(
                        path: path,
                        songs: '$total 首歌曲',
                        onTap: () => onOpen(path),
                      );
                    },
                  ),
          ),
        ]),
      );
}

class FolderTile extends StatelessWidget {
  const FolderTile(
      {super.key, required this.path, required this.songs, this.onTap});
  final String path, songs;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          const Icon(Icons.folder_outlined, size: 30),
          const SizedBox(width: 18),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(path.split(Platform.pathSeparator).last,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(path, style: Theme.of(context).textTheme.bodySmall),
              ])),
          Text(songs),
          const SizedBox(width: 16),
          const Icon(Icons.chevron_right),
        ]),
      ));
}

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage(
      {super.key,
      required this.playlists,
      required this.onCreate,
      required this.onDelete,
      required this.onRename,
      required this.onOpen});
  final Map<String, List<Track>> playlists;
  final VoidCallback onCreate;
  final ValueChanged<String> onDelete;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onOpen;
  @override
  Widget build(BuildContext context) => _SimplePage(
        title: '歌单',
        action: '新建歌单',
        actionCallback: onCreate,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisExtent: 250,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16),
          itemCount: playlists.length,
          itemBuilder: (context, index) {
            final entry = playlists.entries.elementAt(index);
            final cover = entry.value.isEmpty ? '' : entry.value.last.coverPath;
            return Dismissible(
              key: ValueKey(entry.key),
              onDismissed: (_) => onDelete(entry.key),
              child: InkWell(
                onTap: () => onOpen(entry.key),
                onSecondaryTap: () => _showPlaylistMenu(context, entry.key),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Art(
                            color: entry.value.isEmpty
                                ? Theme.of(context).colorScheme.primary
                                : entry.value.last.color,
                            size: 180,
                            coverPath: cover),
                        const SizedBox(height: 10),
                        Text(entry.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('${entry.value.length} 首歌曲'),
                      ]),
                ),
              ),
            );
          },
        ),
      );

  void _showPlaylistMenu(BuildContext context, String name) {
    _showContextMenu(context, header: name, entries: [
      _ContextMenuEntry.item('重命名', onTap: () {
        Navigator.pop(context);
        onRename(name);
      }),
      _ContextMenuEntry.item('删除', onTap: () {
        Navigator.pop(context);
        onDelete(name);
      }, destructive: true),
    ]);
  }
}

class _SimplePage extends StatelessWidget {
  const _SimplePage(
      {required this.title,
      required this.action,
      required this.child,
      this.actionCallback});
  final String title, action;
  final Widget child;
  final VoidCallback? actionCallback;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          FilledButton.icon(
              onPressed: actionCallback,
              icon: const Icon(Icons.add, size: 18),
              label: Text(action))
        ]),
        const SizedBox(height: 22),
        Expanded(child: child)
      ]));
}

class StatsPage extends StatelessWidget {
  const StatsPage({super.key, required this.library});
  final List<Track> library;
  @override
  Widget build(BuildContext context) => _SimplePage(
        title: '库统计',
        action: '刷新',
        child: ListView(children: [
          Wrap(spacing: 12, runSpacing: 12, children: [
            StatCard(label: '总歌曲数', value: '${library.length}'),
            StatCard(
                label: '总时长',
                value:
                    '${library.fold<int>(0, (s, t) => s + _durationSeconds(t.duration)) ~/ 60} 分钟'),
            StatCard(
                label: '艺术家',
                value: '${library.map((t) => t.artist).toSet().length}'),
            StatCard(
                label: '专辑',
                value: '${library.map((t) => t.album).toSet().length}'),
            StatCard(label: '总大小', value: '本地库'),
          ]),
          const SizedBox(height: 26),
          Text('格式分布',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          for (final format in ['FLAC', 'MP3', 'AAC', 'OGG'])
            _Bar(
                label: format,
                value:
                    library.where((t) => t.format.startsWith(format)).length /
                        (library.isEmpty ? 1 : library.length),
                count:
                    '${library.where((t) => t.format.startsWith(format)).length} 首'),
          const SizedBox(height: 25),
          Text('最近播放',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final t in library.take(4))
            ListTile(
                dense: true,
                leading: const Icon(Icons.music_note, size: 18),
                title: Text(t.title),
                trailing: const Text('播放 23 次')),
        ]),
      );
}

int _durationSeconds(String value) {
  final p = value.split(':');
  return p.length == 2 ? int.tryParse(p[0])! * 60 + int.tryParse(p[1])! : 0;
}

class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Container(
      width: 150,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withOpacity(.42),
          borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 9),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700))
      ]));
}

class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.value, required this.count});
  final String label, count;
  final double value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        SizedBox(width: 42, child: Text(label)),
        Expanded(
            child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: value, minHeight: 8))),
        const SizedBox(width: 12),
        SizedBox(
            width: 50,
            child: Text(count, style: Theme.of(context).textTheme.bodySmall))
      ]));
}

class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage(
      {super.key,
      required this.artist,
      required this.onAlbum,
      required this.onPlay});
  final String artist;
  final ValueChanged<String> onAlbum;
  final ValueChanged<int> onPlay;
  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    final songs = tracks.where((t) => t.artist == widget.artist).toList();
    final albums = songs.map((t) => t.album).toSet().toList();
    final cover = songs.isEmpty ? '' : songs.first.coverPath;
    return Padding(
        padding: const EdgeInsets.all(28),
        child: ListView(children: [
          Row(children: [
            _Art(color: Colors.teal, size: 360, coverPath: cover),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.artist,
                        style: Theme.of(context)
                            .textTheme
                            .headlineLarge
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text('${albums.length} 张专辑 · ${songs.length} 首歌曲',
                        style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: songs.isEmpty ? null : () => widget.onPlay(0),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('全部播放')),
                  ]),
            )
          ]),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.4)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ArtistTabButton(
                    label: '歌曲',
                    selected: _tab == 0,
                    onTap: () => setState(() => _tab = 0)),
                _ArtistTabButton(
                    label: '专辑',
                    selected: _tab == 1,
                    onTap: () => setState(() => _tab = 1)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (_tab == 0) ...[
            for (final e in songs.asMap().entries)
              ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: Text('${e.key + 1}'.padLeft(2, '0'),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  title: Text(e.value.title),
                  subtitle: InkWell(
                      onTap: () => widget.onAlbum(e.value.album),
                      child: Text(e.value.album,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.primary))),
                  trailing: Text(e.value.duration),
                  onTap: () => widget.onPlay(e.key)),
          ] else ...[
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180, mainAxisExtent: 230, crossAxisSpacing: 16, mainAxisSpacing: 16),
              itemCount: albums.length,
              itemBuilder: (_, i) => InkWell(
                onTap: () => widget.onAlbum(albums[i]),
                borderRadius: BorderRadius.circular(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _Art(
                          color: Colors.primaries[i % Colors.primaries.length],
                          size: 180),
                    ),
                    const SizedBox(height: 6),
                    Text(albums[i],
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ]));
  }
}

class _ArtistTabButton extends StatelessWidget {
  const _ArtistTabButton(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Theme.of(context).colorScheme.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
}

class AlbumDetailPage extends StatelessWidget {
  const AlbumDetailPage(
      {super.key,
      required this.album,
      required this.onArtist,
      required this.onPlay});
  final String album;
  final ValueChanged<String> onArtist;
  final ValueChanged<int> onPlay;
  @override
  Widget build(BuildContext context) {
    final songs = tracks.where((t) => t.album == album).toList();
    final artist = songs.isEmpty ? '' : songs.first.artist;
    final cover = songs.isNotEmpty ? songs.first.coverPath : '';
    return Padding(
        padding: const EdgeInsets.all(28),
        child: ListView(children: [
          Row(children: [
            _Art(color: Colors.indigo, size: 200, coverPath: cover),
            const SizedBox(width: 22),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(album,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              InkWell(onTap: () => onArtist(artist), child: Text(artist)),
              Text(
                  '${songs.length} 首歌 · ${songs.fold<int>(0, (s, t) => s + _durationSeconds(t.duration)) ~/ 60} 分钟'),
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: songs.isEmpty ? null : () => onPlay(0),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('全部播放'))
            ])
          ]),
          const SizedBox(height: 28),
          const Text('曲目',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ...songs.asMap().entries.map((e) => ListTile(
              dense: true,
              leading: Text('${e.key + 1}'.padLeft(2, '0')),
              title: Text(e.value.title),
              subtitle: InkWell(
                  onTap: () => onArtist(e.value.artist),
                  child: Text(e.value.artist,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary))),
              trailing: Text(e.value.duration),
              onTap: () => onPlay(e.key)))
        ]));
  }
}

class FolderDetailPage extends StatelessWidget {
  const FolderDetailPage(
      {super.key,
      required this.path,
      required this.onBack,
      required this.onOpen,
      required this.onPlay});
  final String path;
  final VoidCallback onBack;
  final ValueChanged<String> onOpen;
  final ValueChanged<Track> onPlay;
  @override
  Widget build(BuildContext context) {
    final children =
        path.isEmpty ? <String>[] : path.split(Platform.pathSeparator);
    final childFolders = <String>{};
    for (final track in tracks.where((track) => track.path.startsWith(path))) {
      final relative = track.path
          .substring(path.length)
          .replaceFirst(RegExp(r'^[\\/]+'), '');
      final separator = relative.indexOf(RegExp(r'[\\/]'));
      if (separator > 0) {
        childFolders.add(
            '$path${Platform.pathSeparator}${relative.substring(0, separator)}');
      }
    }
    return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
            Expanded(
                child: Text(children.join(' / '),
                    maxLines: 1, overflow: TextOverflow.ellipsis))
          ]),
          const Divider(),
          if (childFolders.isNotEmpty) ...[
            for (final folder in childFolders)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FolderTile(
                    path: folder,
                    songs:
                        '${tracks.where((track) => track.path.startsWith(folder)).length} 首歌曲',
                    onTap: () => onOpen(folder)),
              ),
          ],
          Expanded(
              child: _TrackList(
                  songs: tracks
                      .where((track) => track.path.startsWith(path))
                      .toList(),
                  onPlay: onPlay))
        ]));
  }
}

class PlaylistDetailPage extends StatelessWidget {
  const PlaylistDetailPage(
      {super.key,
      required this.name,
      required this.songs,
      required this.onAdd,
      required this.onRemove,
      required this.onReorder,
      required this.onPlay,
      required this.onArtist,
      required this.onAlbum});
  final String name;
  final List<Track> songs;
  final ValueChanged<Track> onAdd, onRemove;
  final void Function(int, int) onReorder;
  final ValueChanged<Track> onPlay;
  final ValueChanged<String> onArtist, onAlbum;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Text('${songs.length} 首歌曲')
          ]),
          const Spacer(),
          PopupMenuButton<Track>(
              tooltip: '添加歌曲',
              icon: const Icon(Icons.add),
              onSelected: onAdd,
              itemBuilder: (_) => [
                    for (final t in tracks)
                      PopupMenuItem(value: t, child: Text(t.title))
                  ])
        ]),
        const SizedBox(height: 18),
        Expanded(
            child: _TrackList(
                songs: songs,
                onPlay: onPlay,
                onArtist: onArtist,
                onAlbum: onAlbum,
                onRemove: onRemove,
                reorderable: true,
                onReorder: onReorder))
      ]));
}

class UnreadablePage extends StatelessWidget {
  const UnreadablePage(
      {super.key,
      required this.items,
      required this.onRelink,
      required this.onRemove,
      required this.onRemoveAll,
      required this.onPlay,
      required this.onArtist,
      required this.onAlbum});
  final Set<Track> items;
  final ValueChanged<Track> onRelink, onRemove;
  final VoidCallback onRemoveAll;
  final ValueChanged<Track> onPlay;
  final ValueChanged<String> onArtist, onAlbum;
  @override
  Widget build(BuildContext context) => _SimplePage(
      title: '不可读曲目',
      action: '批量移除',
      actionCallback: onRemoveAll,
      child: items.isEmpty
          ? const Center(child: Text('没有不可读曲目'))
          : _TrackList(
              songs: items.toList(),
              onPlay: onPlay,
              onArtist: onArtist,
              onAlbum: onAlbum,
              onRemove: onRemove,
              onRelink: onRelink));
}

class SettingsPage extends StatefulWidget {
  const SettingsPage(
      {super.key, required this.themeMode, required this.onThemeChanged});
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = [
      (Icons.palette_outlined, '个性化'),
      (Icons.lyrics_outlined, '歌词'),
      (Icons.info_outline, '关于'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('设置',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 18),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: (value) => setState(() => _tab = value),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final tab in tabs)
                  NavigationRailDestination(
                      icon: Icon(tab.$1), label: Text(tab.$2)),
              ],
            ),
            const VerticalDivider(width: 1),
            const SizedBox(width: 24),
            Expanded(child: _buildTab(context)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildTab(BuildContext context) {
    switch (_tab) {
      case 0:
        return ListView(children: [
          _sectionTitle(context, '外观'),
          RadioListTile<ThemeMode>(
              value: ThemeMode.dark,
              groupValue: widget.themeMode,
              onChanged: (v) {
                if (v != null) widget.onThemeChanged(v);
              },
              title: const Text('深色模式'),
              subtitle: const Text('更适合夜间聆听')),
          RadioListTile<ThemeMode>(
              value: ThemeMode.light,
              groupValue: widget.themeMode,
              onChanged: (v) {
                if (v != null) widget.onThemeChanged(v);
              },
              title: const Text('浅色模式')),
          const Divider(height: 30),
          _sectionTitle(context, '播放'),
          const _SettingsSwitch(title: '启动时恢复上次播放位置', initialValue: true),
          const _SettingsSwitch(title: '无缝播放', initialValue: false),
        ]);
      case 1:
        return ListView(children: [
          _sectionTitle(context, '全屏歌词'),
          const _PersistentSwitch(
              title: '默认显示翻译',
              prefKey: 'lyrics_translation',
              defaultValue: false),
          const _PersistentSwitch(
              title: '逐字高亮',
              prefKey: 'lyrics_word_highlight',
              defaultValue: true),
          const _PersistentSwitch(
              title: '非当前行模糊', prefKey: 'lyrics_blur', defaultValue: true),
          const _PersistentSwitch(
              title: '非当前行淡出', prefKey: 'lyrics_fade', defaultValue: true),
          const _PersistentSwitch(
              title: '远离视野缩放', prefKey: 'lyrics_distant', defaultValue: true),
          const _PersistentSlider(
              title: '歌词字号',
              prefKey: 'lyrics_font_size',
              min: 16,
              max: 48,
              defaultValue: 22,
              suffix: ' px'),
          const _PersistentSlider(
              title: '翻译字号',
              prefKey: 'lyrics_translation_font_size',
              min: 10,
              max: 28,
              defaultValue: 14,
              suffix: ' px'),
          const Divider(height: 30),
          _sectionTitle(context, '桌面歌词'),
          const _PersistentSwitch(
              title: '逐字高亮',
              prefKey: 'desktop_lyrics_word_highlight',
              defaultValue: true),
          const _PersistentSwitch(
              title: '显示翻译',
              prefKey: 'desktop_lyrics_translation',
              defaultValue: true),
          const _PersistentSwitch(
              title: '双行模式', prefKey: 'desktop_lyrics_double_line', defaultValue: true),
          const Divider(height: 30),
          _sectionTitle(context, '视觉效果'),
          const _PersistentSwitch(
              title: '雪花粒子', prefKey: 'lyrics_snow', defaultValue: false),
          const _PersistentSwitch(
              title: '雾气效果', prefKey: 'lyrics_fog', defaultValue: false),
          const _PersistentSwitch(
              title: '雨滴效果', prefKey: 'lyrics_rain', defaultValue: false),
          const Divider(height: 30),
          const Text('更多歌词排版选项可从全屏歌词工具栏打开。',
              style: TextStyle(fontSize: 12)),
        ]);
      default:
        return ListView(children: [
          _sectionTitle(context, '关于 Still'),
          const ListTile(title: Text('版本'), trailing: Text('0.1.0')),
          const ListTile(
              title: Text('界面'), trailing: Text('Flutter Material 3')),
          const ListTile(
              title: Text('说明'), subtitle: Text('本地音乐播放器，支持歌词、歌单和多窗口歌词。')),
        ]);
    }
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
      );
}

class _SettingsSwitch extends StatefulWidget {
  const _SettingsSwitch({required this.title, required this.initialValue});
  final String title;
  final bool initialValue;
  @override
  State<_SettingsSwitch> createState() => _SettingsSwitchState();
}

class _SettingsSwitchState extends State<_SettingsSwitch> {
  late bool value = widget.initialValue;
  @override
  Widget build(BuildContext context) => SwitchListTile(
      value: value,
      onChanged: (next) => setState(() => value = next),
      title: Text(widget.title));
}

class _SettingsRowTile extends StatelessWidget {
  const _SettingsRowTile(
      {required this.title, this.subtitle, required this.child});
  final String title;
  final String? subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(.65),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _ThemeChip extends StatelessWidget {
  const _ThemeChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline.withOpacity(.4)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: selected
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurface)),
      ),
    );
  }
}

class _SettingsTab extends StatelessWidget {
  const _SettingsTab(
      {required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Theme.of(context).colorScheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurface)),
          ],
        ),
      ),
    );
  }
}

class _PersistentSwitch extends StatefulWidget {
  const _PersistentSwitch(
      {required this.title, required this.prefKey, this.defaultValue = false});
  final String title;
  final String prefKey;
  final bool defaultValue;
  @override
  State<_PersistentSwitch> createState() => _PersistentSwitchState();
}

class _PersistentSwitchState extends State<_PersistentSwitch> {
  bool _value = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _value = prefs.getBool(widget.prefKey) ?? widget.defaultValue;
        _loaded = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return SwitchListTile(
        value: _value,
        onChanged: (next) {
          setState(() => _value = next);
          SharedPreferences.getInstance()
              .then((prefs) => prefs.setBool(widget.prefKey, next));
        },
        title: Text(widget.title));
  }
}

class _PersistentSlider extends StatefulWidget {
  const _PersistentSlider({
    required this.title,
    required this.prefKey,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.suffix,
  });
  final String title, prefKey, suffix;
  final double min, max, defaultValue;

  @override
  State<_PersistentSlider> createState() => _PersistentSliderState();
}

class _PersistentSliderState extends State<_PersistentSlider> {
  late double _value = widget.defaultValue;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted)
        setState(() => _value = prefs.getDouble(widget.prefKey) ?? _value);
    });
  }

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(widget.title),
        subtitle: Slider(
          value: _value.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          divisions: (widget.max - widget.min).round(),
          label: '${_value.round()}${widget.suffix}',
          onChanged: (value) => setState(() => _value = value),
          onChangeEnd: (value) => SharedPreferences.getInstance()
              .then((prefs) => prefs.setDouble(widget.prefKey, value)),
        ),
        trailing: Text('${_value.round()}${widget.suffix}'),
      );
}

class TrackInfoDialog extends StatelessWidget {
  const TrackInfoDialog({super.key, required this.track});
  final Track track;
  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Colors.transparent,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 430,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface.withOpacity(.92),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: Theme.of(context).colorScheme.outline.withOpacity(.15)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(.2), blurRadius: 24)
              ],
            ),
            child: SingleChildScrollView(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  _Art(
                      color: track.color, size: 72, coverPath: track.coverPath),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(track.title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 16)),
                          const SizedBox(height: 4),
                          Text(track.artist),
                          Text(track.album,
                              style: Theme.of(context).textTheme.bodySmall),
                        ]),
                  ),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18)),
                ]),
                const Divider(height: 28),
                _InfoLine('格式', track.format.isNotEmpty ? track.format : '未知'),
                _InfoLine('时长', track.duration.isNotEmpty ? track.duration : '未知'),
                _InfoLine('年份', track.year.isNotEmpty ? track.year : '未知'),
                _InfoLine('文件路径', track.path.isNotEmpty ? track.path : '未知'),
                _InfoLine('歌词来源', track.embeddedLyrics.isNotEmpty ? '内嵌歌词' : '无歌词'),
              ],
            )),
          ),
        ),
      );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 80,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(child: Text(value))
      ]));
}

enum _LyricsDisplayMode { lyrics, cover, mixHorizontal, mixVertical }

class LyricsSheet extends StatefulWidget {
  const LyricsSheet(
      {super.key, required this.track, required this.positionListenable});
  final Track track;
  final ValueListenable<Duration> positionListenable;
  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  _LyricsDisplayMode _displayMode = _LyricsDisplayMode.lyrics;
  bool _translated = false;
  double _timeOffset = 0;
  final _scroll = ScrollController();
  List<LyricLine> _lines = const [];
  int _activeLine = 0;
  bool _hudVisible = true;
  Timer? _hudTimer;
  bool _showCopyDialog = false;
  bool _showOffsetDialog = false;
  bool _showSettingsDialog = false;
  bool _showSourceMenu = false;
  LyricsSourceType _source = LyricsSourceType.localFile;
  double _fontSize = 22;
  double _translationFontSize = 14;
  FontWeight _fontWeight = FontWeight.w500;
  bool _snowEnabled = false;
  bool _fogEnabled = false;
  bool _rainEnabled = false;
  bool _wordHighlight = true;
  bool _blurEnabled = true;
  bool _fadeEnabled = true;
  bool _distantEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadLyrics();
    _loadEffectSettings();
    widget.positionListenable.addListener(_syncPlaybackPosition);
    _startHudTimer();
  }

  Future<void> _loadEffectSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _snowEnabled = prefs.getBool('lyrics_snow') ?? false;
      _fogEnabled = prefs.getBool('lyrics_fog') ?? false;
      _rainEnabled = prefs.getBool('lyrics_rain') ?? false;
      _translated = prefs.getBool('lyrics_translation') ?? false;
      _wordHighlight = prefs.getBool('lyrics_word_highlight') ?? true;
      _blurEnabled = prefs.getBool('lyrics_blur') ?? true;
      _fadeEnabled = prefs.getBool('lyrics_fade') ?? true;
      _distantEnabled = prefs.getBool('lyrics_distant') ?? true;
      _fontSize = prefs.getDouble('lyrics_font_size') ?? 22;
      _translationFontSize =
          prefs.getDouble('lyrics_translation_font_size') ?? 14;
    });
  }

  void _syncPlaybackPosition() {
    if (!mounted || _lines.isEmpty) return;
    final position = widget.positionListenable.value +
        Duration(milliseconds: (_timeOffset * 1000).round());
    var next = 0;
    for (var index = 0; index < _lines.length; index++) {
      if (_lines[index].timestamp <= position)
        next = index;
      else
        break;
    }
    if (next == _activeLine) return;
    setState(() => _activeLine = next);
    if (_scroll.hasClients) {
      _scroll.animateTo(
        (next * 76.0).clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _startHudTimer() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  void _onPointerMove() {
    setState(() => _hudVisible = true);
    _startHudTimer();
  }

  Future<void> _loadLyrics([LyricsSourceType? requestedSource]) async {
    final source = requestedSource ?? _source;
    _source = source;
    if (source == LyricsSourceType.embedded &&
        widget.track.embeddedLyrics.trim().isNotEmpty) {
      setState(() =>
          _lines = const LrcParser().parse(widget.track.embeddedLyrics).lines);
      _syncPlaybackPosition();
      return;
    }
    final path = widget.track.path.replaceFirst(RegExp(r'\.[^.\\/]+$'), '.lrc');
    try {
      final file = File(path);
      if (await file.exists()) {
        final parsed = const LrcParser().parse(await file.readAsString());
        if (mounted) setState(() => _lines = parsed.lines);
      }
    } catch (_) {}
    if (mounted && _lines.isEmpty) {
      setState(() => _lines = [LyricLine(Duration.zero, widget.track.title)]);
    }
    _syncPlaybackPosition();
  }

  @override
  void dispose() {
    widget.positionListenable.removeListener(_syncPlaybackPosition);
    _hudTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  String _formatOffset(double value) {
    final sign = value >= 0 ? '+' : '';
    return '$sign${value.toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => _onPointerMove(),
      child: GestureDetector(
        onTap: _onPointerMove,
        child: Material(
          color: const Color(0xff0a0c14),
          child: Stack(
            children: [
              Positioned.fill(
                child: LyricsEffectsStack(
                  settings: LyricsBackgroundSettings(
                    mode: LyricsBackgroundMode.fluid,
                    snowEnabled: _snowEnabled,
                    fogEnabled: _fogEnabled,
                    raindropsEnabled: _rainEnabled,
                  ),
                  baseColor: widget.track.color,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(.65),
                        Colors.black.withOpacity(.78),
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      children: [
                        Column(
                          children: [
                            _buildTopHud(),
                            Expanded(child: _buildContent(constraints)),
                          ],
                        ),
                        Positioned(
                          right: 24,
                          top: 80,
                          child: _buildRightToolbar(),
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (_showCopyDialog) _buildCopyDialog(),
              if (_showOffsetDialog) _buildOffsetDialog(),
              if (_showSettingsDialog) _buildSettingsDialog(),
              if (_showSourceMenu) _buildSourceMenu(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopHud() {
    return AnimatedOpacity(
      opacity: _hudVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          children: [
            IconButton(
              tooltip: '关闭歌词',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.keyboard_arrow_down,
                  color: Colors.white, size: 28),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.track.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.track.artist} · ${widget.track.album}',
                    style: TextStyle(
                        color: Colors.white.withOpacity(.7), fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            _buildModeButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildModeButtons() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.1),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModeButton(
            icon: Icons.lyrics_outlined,
            tooltip: '纯歌词',
            active: _displayMode == _LyricsDisplayMode.lyrics,
            onTap: () =>
                setState(() => _displayMode = _LyricsDisplayMode.lyrics),
          ),
          _ModeButton(
            icon: Icons.image_outlined,
            tooltip: '纯封面',
            active: _displayMode == _LyricsDisplayMode.cover,
            onTap: () =>
                setState(() => _displayMode = _LyricsDisplayMode.cover),
          ),
          _ModeButton(
            icon: Icons.view_column_outlined,
            tooltip: '混合横屏',
            active: _displayMode == _LyricsDisplayMode.mixHorizontal,
            onTap: () =>
                setState(() => _displayMode = _LyricsDisplayMode.mixHorizontal),
          ),
          _ModeButton(
            icon: Icons.view_agenda_outlined,
            tooltip: '混合竖屏',
            active: _displayMode == _LyricsDisplayMode.mixVertical,
            onTap: () =>
                setState(() => _displayMode = _LyricsDisplayMode.mixVertical),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BoxConstraints constraints) {
    final mode = _displayMode;

    // Calculate cover position and size for each mode
    double coverSize;
    double coverTop;
    double coverLeft;
    bool showCoverInfo;
    bool showLyrics;
    bool lyricsWide;

    switch (mode) {
      case _LyricsDisplayMode.lyrics:
        coverSize = 120;
        coverTop = 12;
        coverLeft = constraints.maxWidth * 0.5 - coverSize * 0.5;
        showCoverInfo = false;
        showLyrics = true;
        lyricsWide = false;
        break;
      case _LyricsDisplayMode.cover:
        coverSize = constraints.maxHeight * 0.5;
        coverTop = constraints.maxHeight * 0.12;
        coverLeft = constraints.maxWidth * 0.5 - coverSize * 0.5;
        showCoverInfo = true;
        showLyrics = false;
        lyricsWide = false;
        break;
      case _LyricsDisplayMode.mixHorizontal:
        coverSize = constraints.maxWidth * 0.35 * 0.8;
        coverTop = constraints.maxHeight * 0.5 - coverSize * 0.5 - 40;
        coverLeft = 48;
        showCoverInfo = true;
        showLyrics = true;
        lyricsWide = true;
        break;
      case _LyricsDisplayMode.mixVertical:
        coverSize = 72;
        coverTop = 24;
        coverLeft = constraints.maxWidth * 0.5 - coverSize * 0.5 - 60;
        showCoverInfo = true;
        showLyrics = true;
        lyricsWide = false;
        break;
    }

    return Stack(
      children: [
        // Lyrics content
        if (showLyrics)
          Positioned.fill(
            child: lyricsWide
                ? Padding(
                    padding: EdgeInsets.only(
                      left: coverSize + 48 + 48,
                      right: 80,
                    ),
                    child: _buildLyricsList(wide: true),
                  )
                : _buildLyricsList(wide: false),
          ),

        // Animated cover art
        if (coverSize > 0)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
            top: coverTop,
            left: coverLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              width: coverSize,
              height: coverSize,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Hero(
                    tag: 'active-cover',
                    child: _AnimatedCoverArt(
                      size: coverSize,
                      color: widget.track.color,
                      borderRadius:
                          mode == _LyricsDisplayMode.mixVertical ? 12 : 16,
                      coverPath: widget.track.coverPath,
                    ),
                  ),
                  if (showCoverInfo &&
                      mode != _LyricsDisplayMode.mixVertical) ...[
                    const SizedBox(height: 16),
                    AnimatedOpacity(
                      opacity: 1.0,
                      duration: const Duration(milliseconds: 300),
                      child: Column(
                        children: [
                          Text(
                            widget.track.title,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize:
                                  mode == _LyricsDisplayMode.cover ? 22 : 18,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.track.artist,
                            style: TextStyle(
                              color: Colors.white.withOpacity(.7),
                              fontSize:
                                  mode == _LyricsDisplayMode.cover ? 15 : 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (mode == _LyricsDisplayMode.mixHorizontal) ...[
                            const SizedBox(height: 4),
                            Text(
                              widget.track.album,
                              style: TextStyle(
                                  color: Colors.white.withOpacity(.5),
                                  fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

        // Mix vertical mode: show info next to cover
        if (mode == _LyricsDisplayMode.mixVertical)
          Positioned(
            top: 24 + 10,
            left: constraints.maxWidth * 0.5 - 60 + 72 + 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.track.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.track.artist} · ${widget.track.album}',
                  style: TextStyle(
                      color: Colors.white.withOpacity(.7), fontSize: 13),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLyricsList({required bool wide}) {
    final viewportHeight = MediaQuery.of(context).size.height;
    final autoScale = (viewportHeight / 1080).clamp(0.72, 1.18);
    final scaledFontSize = _fontSize * autoScale;
    final scaledTranslationSize = _translationFontSize * autoScale;
    return ListView.builder(
      controller: _scroll,
      itemCount: _lines.length,
      padding: EdgeInsets.symmetric(
        vertical:
            wide ? 80 : (_displayMode == _LyricsDisplayMode.lyrics ? 180 : 100),
        horizontal: wide ? 24 : 48,
      ),
      itemBuilder: (_, index) => _buildLyricLine(index, scaledFontSize,
          scaledTranslationSize: scaledTranslationSize, wide: wide),
    );
  }

  Widget _buildLyricLine(int index, double fontSize,
      {double scaledTranslationSize = 14, bool wide = false}) {
    final line = _lines[index];
    final active = index == _activeLine;
    final distance = (index - _activeLine).abs();
    final opacity =
        _fadeEnabled ? (1.0 - distance * 0.08).clamp(0.3, 1.0) : 1.0;
    final scale =
        _distantEnabled ? (1.0 - distance * 0.02).clamp(0.88, 1.0) : 1.0;

    return GestureDetector(
      onTap: () {
        _scroll.animateTo(
          index * 76.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.centerLeft,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(
                sigmaX: _blurEnabled && !active ? .8 : 0,
                sigmaY: _blurEnabled && !active ? .8 : 0),
            child: Column(
              crossAxisAlignment:
                  wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  textAlign: wide ? TextAlign.left : TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(active ? 1.0 : opacity),
                    fontSize: active ? fontSize : fontSize * 0.95,
                    fontWeight: active ? FontWeight.w700 : _fontWeight,
                  ),
                  child: active && _wordHighlight && line.words.isNotEmpty
                      ? ValueListenableBuilder<Duration>(
                          valueListenable: widget.positionListenable,
                          builder: (_, position, __) => Text.rich(
                            TextSpan(
                              children: [
                                for (var wordIndex = 0;
                                    wordIndex < line.words.length;
                                    wordIndex++)
                                  TextSpan(
                                    text: line.words[wordIndex].text,
                                    style: TextStyle(
                                      color: position +
                                                  Duration(
                                                      milliseconds:
                                                          (_timeOffset * 1000)
                                                              .round()) >=
                                              line.words[wordIndex].timestamp
                                          ? Colors.white
                                          : Colors.white.withOpacity(.36),
                                    ),
                                  ),
                              ],
                            ),
                            textAlign: wide ? TextAlign.left : TextAlign.center,
                          ),
                        )
                      : Text(line.text),
                ),
                    if (_translated && line.translation != null) ...[
                  const SizedBox(height: 4),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    textAlign: wide ? TextAlign.left : TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(active ? 0.5 : 0.3),
                      fontSize: scaledTranslationSize,
                      fontWeight: FontWeight.w400,
                    ),
                    child: Text(line.translation!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRightToolbar() {
    return AnimatedOpacity(
      opacity: _hudVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.1),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolbarButton(
              icon: Icons.layers_outlined,
              tooltip: '歌词源',
              onTap: () => setState(() => _showSourceMenu = true),
            ),
            const SizedBox(height: 8),
            _ToolbarButton(
              icon: Icons.translate,
              tooltip: _translated ? '关闭翻译' : '显示翻译',
              active: _translated,
              onTap: () => setState(() => _translated = !_translated),
            ),
            const SizedBox(height: 8),
            _ToolbarButton(
              icon: Icons.copy,
              tooltip: '复制歌词',
              onTap: () => setState(() => _showCopyDialog = true),
            ),
            const SizedBox(height: 8),
            _ToolbarButton(
              icon: Icons.timer_outlined,
              tooltip: '歌词偏移',
              active: _timeOffset.abs() > 0.01,
              onTap: () => setState(() => _showOffsetDialog = true),
            ),
            const SizedBox(height: 8),
            _ToolbarButton(
              icon: Icons.tune,
              tooltip: '歌词设置',
              onTap: () => setState(() => _showSettingsDialog = true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceMenu() {
    return GestureDetector(
      onTap: () => setState(() => _showSourceMenu = false),
      child: Container(
        color: Colors.black.withOpacity(.3),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 220,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withOpacity(.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outline.withOpacity(.15)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(.4), blurRadius: 24)
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('歌词源',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  _SourceItem(
                      label: '内嵌歌词',
                      type: LyricsSourceType.embedded,
                      active: _source == LyricsSourceType.embedded,
                      enabled: widget.track.embeddedLyrics.trim().isNotEmpty,
                      onTap: () {
                        _loadLyrics(LyricsSourceType.embedded);
                        setState(() => _showSourceMenu = false);
                      }),
                  const SizedBox(height: 8),
                  _SourceItem(
                      label: '本地 LRC 文件',
                      type: LyricsSourceType.localFile,
                      active: _source == LyricsSourceType.localFile,
                      onTap: () {
                        _loadLyrics(LyricsSourceType.localFile);
                        setState(() => _showSourceMenu = false);
                      }),
                  const SizedBox(height: 8),
                  _SourceItem(
                      label: '在线歌词（插件）',
                      type: LyricsSourceType.online,
                      enabled: false,
                      onTap: () {}),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _showSourceMenu = false),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCopyDialog() {
    return GestureDetector(
      onTap: () => setState(() => _showCopyDialog = false),
      child: Container(
        color: Colors.black.withOpacity(.3),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 480,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7,
              ),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xff1e2028),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 24)
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('复制歌词',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () =>
                            setState(() => _showCopyDialog = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _lines.length,
                      itemBuilder: (_, index) {
                        final line = _lines[index];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 12),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.05),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(line.text,
                                  style: const TextStyle(color: Colors.white)),
                              if (line.translation != null)
                                Text(
                                  line.translation!,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(.5),
                                      fontSize: 12),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () async {
                        final text = _lines.map((l) {
                          if (_translated && l.translation != null) {
                            return '${l.text}\n${l.translation}';
                          }
                          return l.text;
                        }).join('\n');
                        await Clipboard.setData(ClipboardData(text: text));
                        if (context.mounted) {
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('已复制 ${_lines.length} 行歌词到剪贴板')),
                          );
                        }
                      },
                      child: const Text('复制全部'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOffsetDialog() {
    return GestureDetector(
      onTap: () => setState(() => _showOffsetDialog = false),
      child: Container(
        color: Colors.black.withOpacity(.3),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 400,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xff1e2028),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 24)
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('歌词偏移',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  Text(
                    _formatOffset(_timeOffset),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  Slider(
                    value: _timeOffset.clamp(-5.0, 5.0),
                    min: -5,
                    max: 5,
                    divisions: 100,
                    activeColor: Theme.of(context).colorScheme.primary,
                    onChanged: (v) => setState(() => _timeOffset = v),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    children: [-5.0, -2.0, -1.0, 0.0, 1.0, 2.0, 5.0].map((v) {
                      return ActionChip(
                        label: Text(_formatOffset(v),
                            style: TextStyle(
                              color: _timeOffset == v
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white70,
                            )),
                        onPressed: () => setState(() => _timeOffset = v),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () =>
                          setState(() => _showOffsetDialog = false),
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsDialog() {
    return GestureDetector(
      onTap: () => setState(() => _showSettingsDialog = false),
      child: Container(
        color: Colors.black.withOpacity(.3),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 840,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.82,
              ),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withOpacity(.96),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(.4), blurRadius: 24)
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('歌词设置',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () =>
                            setState(() => _showSettingsDialog = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        _SettingsRow(
                          label: '歌词字体大小',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove, size: 18),
                                onPressed: () => setState(() =>
                                    _fontSize = (_fontSize - 2).clamp(14, 48)),
                              ),
                              SizedBox(
                                width: 48,
                                child: Text('${_fontSize.round()}px',
                                    textAlign: TextAlign.center),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add, size: 18),
                                onPressed: () => setState(() =>
                                    _fontSize = (_fontSize + 2).clamp(14, 48)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _SettingsRow(
                          label: '翻译字体大小',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove, size: 18),
                                onPressed: () => setState(() =>
                                    _translationFontSize =
                                        (_translationFontSize - 1)
                                            .clamp(10, 28)),
                              ),
                              SizedBox(
                                width: 48,
                                child: Text('${_translationFontSize.round()}px',
                                    textAlign: TextAlign.center),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add, size: 18),
                                onPressed: () => setState(() =>
                                    _translationFontSize =
                                        (_translationFontSize + 1)
                                            .clamp(10, 28)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _SettingsRow(
                          label: '歌词字重',
                          child: DropdownButton<FontWeight>(
                            value: _fontWeight,
                            underline: const SizedBox(),
                            isDense: true,
                            items: const [
                              DropdownMenuItem(
                                  value: FontWeight.w400, child: Text('常规')),
                              DropdownMenuItem(
                                  value: FontWeight.w500, child: Text('中等')),
                              DropdownMenuItem(
                                  value: FontWeight.w600, child: Text('半粗')),
                              DropdownMenuItem(
                                  value: FontWeight.w700, child: Text('粗体')),
                            ],
                            onChanged: (v) => setState(
                                () => _fontWeight = v ?? FontWeight.w500),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Wrap(
                          spacing: 16,
                          runSpacing: 8,
                          children: [
                            _SettingsSwitchCompact(
                                label: '逐字高亮',
                                value: _wordHighlight,
                                onChanged: (v) => setState(() => _wordHighlight = v)),
                            _SettingsSwitchCompact(
                                label: '非当前行模糊',
                                value: _blurEnabled,
                                onChanged: (v) => setState(() => _blurEnabled = v)),
                            _SettingsSwitchCompact(
                                label: '非当前行淡出',
                                value: _fadeEnabled,
                                onChanged: (v) => setState(() => _fadeEnabled = v)),
                            _SettingsSwitchCompact(
                                label: '远离缩放',
                                value: _distantEnabled,
                                onChanged: (v) => setState(() => _distantEnabled = v)),
                            _SettingsSwitchCompact(
                                label: '显示翻译',
                                value: _translated,
                                onChanged: (v) => setState(() => _translated = v)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedCoverArt extends StatelessWidget {
  const _AnimatedCoverArt({
    required this.size,
    required this.color,
    this.borderRadius = 16,
    this.coverPath = '',
  });
  final double size;
  final Color color;
  final double borderRadius;
  final String coverPath;

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: [
        BoxShadow(
          color: color.withOpacity(.4),
          blurRadius: 32,
          offset: const Offset(0, 8),
        ),
      ],
    );

    if (coverPath.isNotEmpty) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: decoration,
        child: Image.file(
          File(coverPath),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildFallback(),
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      decoration: decoration,
      child: _buildFallback(),
    );
  }

  Widget _buildFallback() => Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Icon(
          Icons.music_note,
          color: Colors.white.withOpacity(.76),
          size: size * .42,
        ),
      );
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active ? Colors.white.withOpacity(.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary.withOpacity(.3)
                : Colors.white.withOpacity(.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color:
                active ? Theme.of(context).colorScheme.primary : Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class _SourceItem extends StatelessWidget {
  const _SourceItem({
    required this.label,
    required this.type,
    required this.onTap,
    this.active = false,
    this.enabled = true,
  });
  final String label;
  final LyricsSourceType type;
  final VoidCallback onTap;
  final bool active, enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary.withOpacity(.24)
                : Colors.white.withOpacity(.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                type == LyricsSourceType.embedded
                    ? Icons.audiotrack
                    : type == LyricsSourceType.localFile
                        ? Icons.folder_open
                        : Icons.language,
                color: enabled ? Colors.white54 : Colors.white24,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(label,
                      style: TextStyle(
                          color: enabled ? Colors.white70 : Colors.white38,
                          fontSize: 13))),
            ],
          ),
        ));
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13)),
        child,
      ],
    );
  }
}

class _SettingsSwitchCompact extends StatelessWidget {
  const _SettingsSwitchCompact(
      {required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: value
              ? Theme.of(context).colorScheme.primary.withOpacity(.12)
              : Theme.of(context).colorScheme.surface.withOpacity(.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: value
                  ? Theme.of(context).colorScheme.primary.withOpacity(.3)
                  : Theme.of(context).colorScheme.outline.withOpacity(.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(value ? Icons.check : Icons.close,
                size: 14,
                color: value
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
