import 'dart:ui';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'services/audio/just_audio_backend.dart';
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
          SharedPreferences.getInstance().then((p) => p.setBool('dark_mode', mode == ThemeMode.dark));
        },
      ),
      ),
    );
  }
}

class Track {
  const Track(this.title, this.artist, this.album, this.duration, this.format,
      this.color, [this.path = '', this.coverPath = '']);
  final String title;
  final String artist;
  final String album;
  final String duration;
  final String format;
  final Color color;
  final String path;
  final String coverPath;
}

final tracks = <Track>[];

enum LibraryPage { songs, artists, artistDetail, albums, albumDetail, folders, folderDetail, playlists, playlistDetail, stats, unreadable, settings }

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
  final List<LibraryPage> _history = <LibraryPage>[];
  bool _sidebarExpanded = true;
  bool _playing = false;
  bool _shuffle = false;
  double _volume = .72;
  double _playbackSpeed = 1;
  bool _muted = false;
  bool _desktopLyricsVisible = false;
  PlaybackMode _loopMode = PlaybackMode.sequential;
  Duration _position = Duration.zero;
  String _query = '';
  String _sort = '添加时间';
  bool _grid = false;
  bool _dragActive = false;
  bool _scanning = false;
  double _scanProgress = 0;
  String? _scanStatus;
  int _current = 0;
  String? _selectedArtist;
  String? _selectedAlbum;
  String _folderPath = '';
  String? _selectedPlaylist;
  final List<String> _folders = <String>[];
  final Map<String, List<Track>> _playlists = <String, List<Track>>{};
  final Set<Track> _unreadable = <Track>{};
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
        _audioEngine = AudioEngine(backend: JustAudioBackend());
        _audioSubscription = _audioEngine!.snapshots.listen((snapshot) {
          if (!mounted) return;
          setState(() {
            _playing = snapshot.playback.isPlaying;
            _position = snapshot.position;
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
          onPrevious: () => _playIndex((_current - 1 + tracks.length) % tracks.length),
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
    super.dispose();
  }

  Future<void> _restoreLibrary() async {
    final savedFolders = await _database.folders();
    final savedSongs = await _database.songs();
    if (!mounted) return;
    final existingSongs = <Song>[];
    for (final song in savedSongs) {
      if (song.path.isNotEmpty && await File(song.path).exists()) {
        existingSongs.add(song);
      }
    }
    setState(() {
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
    if (existingSongs.length != savedSongs.length) {
      await _database.saveSongs(existingSongs);
    }
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
      );

  static final _palette = [
    const Color(0xff365a68), const Color(0xffc08b58), const Color(0xff516c68),
    const Color(0xff524c72), const Color(0xffb66555), const Color(0xff7e654c),
    const Color(0xff93675e), const Color(0xff4b607b), const Color(0xff6b5b73),
    const Color(0xff8a6d5b), const Color(0xff5a7c6b), const Color(0xff7b6a8a),
    const Color(0xffa0705a), const Color(0xff4e6e7e), const Color(0xff6e8060),
    const Color(0xff8c5e5e),
  ];

  static Color _colorFromHash(int hash) => _palette[hash.abs() % _palette.length];

  Future<void> _playIndex(int index) async {
    final snapshot = List<Track>.from(tracks);
    if (index < 0 || index >= snapshot.length) return;
    final engine = _audioEngine;
    final selectedTrack = snapshot[index];
    if (engine == null) return;
    if (selectedTrack.path.isEmpty ||
        !await File(selectedTrack.path).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先扫描实际存在的音乐文件')),
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
        AudioTrack(id: i, filePath: playableTracks[i].path, title: playableTracks[i].title, artist: playableTracks[i].artist, album: playableTracks[i].album, duration: _parseDuration(playableTracks[i].duration)),
    ];
    try {
      await engine.loadQueue(queue, initialIndex: 0, autoplay: true);
      await engine.setMode(_shuffle ? PlaybackMode.shuffle : _loopMode);
      final memory = await _playbackMemory.load(selectedTrack.path);
      if (memory != null && memory.position > Duration.zero) {
        await engine.seek(memory.position);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _playing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法播放此文件：$error')),
      );
    }
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

  static Duration _parseDuration(String value) {
    final parts = value.split(':').map(int.tryParse).toList();
    if (parts.length == 2 && parts[0] != null && parts[1] != null) return Duration(minutes: parts[0]!, seconds: parts[1]!);
    return Duration.zero;
  }

  Track get currentTrack => tracks.isEmpty ? const Track('', '', '', '', '', Colors.grey) : tracks[_current.clamp(0, tracks.length - 1)];

  void _select(LibraryPage page) {
    if (page == _page) return;
    setState(() {
      _history.add(_page);
      _page = page;
    });
  }

  void _openArtist(String artist) => setState(() { _selectedArtist = artist; _history.add(_page); _page = LibraryPage.artistDetail; });
  void _openAlbum(String album) => setState(() { _selectedAlbum = album; _history.add(_page); _page = LibraryPage.albumDetail; });
  void _openFolder(String path) => setState(() { _folderPath = path; _history.add(_page); _page = LibraryPage.folderDetail; });
  void _openPlaylist(String name) => setState(() { _selectedPlaylist = name; _history.add(_page); _page = LibraryPage.playlistDetail; });

  void _goBack() {
    if (_history.isEmpty) return;
    setState(() => _page = _history.removeLast());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragActive = true),
      onDragExited: (_) => setState(() => _dragActive = false),
      onDragDone: (detail) {
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
        return Column(children: [
          _TitleBar(
              page: _page,
              onBack: _goBack,
              onForward: () {},
              onSettings: () => _select(LibraryPage.settings)),
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
                child: Column(children: [
              Expanded(child: _buildPage()),
              _PlaybackBar(
                track: currentTrack,
                playing: _playing,
                mode: _shuffle ? PlaybackMode.shuffle : _loopMode,
                volume: _volume,
                speed: _playbackSpeed,
                desktopLyricsVisible: _desktopLyricsVisible,
                onPlay: _togglePlayback,
                onPrevious: () async => _playIndex((_current - 1 + tracks.length) % tracks.length),
                onNext: () async => _playIndex((_current + 1) % tracks.length),
                onStop: () async {
                  await _audioEngine?.stop();
                  if (mounted) setState(() { _playing = false; _position = Duration.zero; });
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
                  final currentMode = _shuffle ? PlaybackMode.shuffle : _loopMode;
                  final mode = switch (currentMode) {
                    PlaybackMode.sequential => PlaybackMode.playlistLoop,
                    PlaybackMode.playlistLoop => PlaybackMode.singleTrackLoop,
                    PlaybackMode.singleTrackLoop => PlaybackMode.shuffle,
                    PlaybackMode.shuffle => PlaybackMode.sequential,
                  };
                  setState(() {
                    _shuffle = mode == PlaybackMode.shuffle;
                    _loopMode = mode == PlaybackMode.shuffle ? PlaybackMode.sequential : mode;
                  });
                  await _audioEngine?.setMode(mode);
                },
                position: _position,
                onSeek: (value) async {
                  setState(() => _position = value);
                  await _audioEngine?.seek(value);
                  await _playbackMemory.save(currentTrack.path, value);
                },
                onLyrics: () => _showLyrics(context),
                onDesktopLyrics: () async {
                  final next = !_desktopLyricsVisible;
                  setState(() => _desktopLyricsVisible = next);
                  if (next) {
                    await _desktopWindowService.show(DesktopWindowKind.lyrics);
                  } else {
                    await _desktopWindowService.hide(DesktopWindowKind.lyrics);
                  }
                },
                onSpeed: (speed) async {
                  setState(() => _playbackSpeed = speed);
                  await _audioEngine?.setSpeed(speed);
                },
                onPlaylist: () => _showQueue(context),
              ),
            ])),
          ])),
        ]);
          }),
        ),
        if (_dragActive)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: .16),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3,
                  ),
                ),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 18),
                    color: Theme.of(context).colorScheme.surface,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.file_download_outlined, size: 42),
                        SizedBox(height: 8),
                        Text('松开以扫描音乐文件或文件夹'),
                      ],
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
            onQuery: (v) => setState(() => _query = v),
            onSort: (v) => setState(() => _sort = v),
            onGrid: () => setState(() => _grid = !_grid),
            onPlay: _playIndex);
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
            counts: sortedArtists.take(50).map((e) => '${e.value} 首歌曲').toList(),
            onTap: _openArtist);
      case LibraryPage.artistDetail:
        return ArtistDetailPage(artist: _selectedArtist ?? '', onAlbum: _openAlbum, onPlay: (i) => setState(() { final s = tracks.where((t) => t.artist == _selectedArtist).toList(); if (s.isNotEmpty) _current = tracks.indexOf(s[i.clamp(0, s.length - 1) as int]); _playing = true; }));
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
        return AlbumDetailPage(album: _selectedAlbum ?? '', onArtist: _openArtist, onPlay: (i) => setState(() { final s = tracks.where((t) => t.album == _selectedAlbum).toList(); if (s.isNotEmpty) _current = tracks.indexOf(s[i.clamp(0, s.length - 1) as int]); _playing = true; }));
      case LibraryPage.folders:
        return FoldersPage(folders: _folders, onAdd: _addFolder, onOpen: _openFolder);
      case LibraryPage.folderDetail:
        return FolderDetailPage(path: _folderPath, onBack: _goBack, onOpen: _openFolder);
      case LibraryPage.playlists:
        return PlaylistsPage(playlists: _playlists, onCreate: _createPlaylist, onDelete: _deletePlaylist, onRename: _renamePlaylist, onOpen: _openPlaylist);
      case LibraryPage.playlistDetail:
        final name = _selectedPlaylist ?? '';
        return PlaylistDetailPage(name: name, songs: _playlists[name] ?? const [], onAdd: (t) => setState(() { final l = _playlists[name]!; if (!l.contains(t)) l.add(t); }), onRemove: (t) => setState(() => _playlists[name]?.remove(t)), onReorder: (a,b) => setState(() { final l = _playlists[name]!; final x=l.removeAt(a); l.insert(b > a ? b-1 : b, x); }));
      case LibraryPage.stats:
        return StatsPage(library: tracks);
      case LibraryPage.unreadable:
        return UnreadablePage(items: _unreadable, onRelink: _relink, onRemove: (t) => setState(() => _unreadable.remove(t)), onRemoveAll: () => setState(() => _unreadable.clear()));
      case LibraryPage.settings:
        return SettingsPage(
            themeMode: widget.themeMode, onThemeChanged: widget.onThemeChanged);
    }
  }

  Future<void> _addFolder() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('添加文件夹'), content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: '输入文件夹路径')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('扫描'))]));
    if (path == null || path.isEmpty) return;
    if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.directory) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('路径不是可扫描的文件夹')));
      return;
    }
    await _scanPaths([path], folders: [path]);
  }

  Future<void> _handleDroppedPaths(Iterable<String> paths) async {
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
      } else if (type == FileSystemEntityType.file && ScannerService.supportedExtensions.contains(_extension(path))) {
        roots.add(path);
      }
    }
    if (roots.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有找到可扫描的音乐文件')));
      return;
    }
    await _scanPaths(roots, folders: folders);
  }

  Future<void> _scanPaths(Iterable<String> roots, {Iterable<String> folders = const []}) async {
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
      final songs = await ScannerService().scan(scanRoots, onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          _scanProgress = progress.fraction;
          _scanStatus = '已扫描 ${progress.scanned}/${progress.total} 首';
        });
      });
      final storedSongs = await _database.songs();
      final songsByPath = <String, Song>{
        for (final song in storedSongs) song.path: song,
        for (final song in songs) song.path: song,
      };
      await _database.saveSongs(songsByPath.values);
      if (mounted && songs.isNotEmpty) {
        setState(() {
          for (final song in songs) {
            final index = tracks.indexWhere((track) => track.path == song.path);
            if (index == -1) {
              tracks.add(_trackFromSong(song));
            } else {
              tracks[index] = _trackFromSong(song);
            }
          }
        });
      }
      final prefs = await SharedPreferences.getInstance();
      for (final path in scanRoots) {
        await prefs.setInt('scan_${path.hashCode}', DateTime.now().millisecondsSinceEpoch);
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('扫描完成，发现 ${songs.length} 首歌曲')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('扫描失败：$error')));
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
  static String _formatSongDuration(Duration value) => '${value.inMinutes.toString().padLeft(2, '0')}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  void _createPlaylist() async { final c=TextEditingController(); final n=await showDialog<String>(context: context,builder:(_)=>AlertDialog(title:const Text('新建歌单'),content:TextField(controller:c,autofocus:true),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('取消')),FilledButton(onPressed:()=>Navigator.pop(context,c.text.trim()),child:const Text('创建'))])); if(n!=null&&n.isNotEmpty)setState(()=>_playlists[n]=[]); }
  void _deletePlaylist(String n) => setState(() => _playlists.remove(n));
  void _renamePlaylist(String oldName) async { final c = TextEditingController(text: oldName); final n = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('重命名歌单'), content: TextField(controller: c, autofocus: true), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('保存'))])); if (n != null && n.isNotEmpty && n != oldName) setState(() { _playlists[n] = _playlists.remove(oldName)!; }); }
  void _relink(Track t) async { final c=TextEditingController(text:t.path); final p=await showDialog<String>(context:context,builder:(_)=>AlertDialog(title:const Text('重新链接文件'),content:TextField(controller:c),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('取消')),FilledButton(onPressed:()=>Navigator.pop(context,c.text),child:const Text('确定'))])); if(p!=null) setState(()=>_unreadable.remove(t)); }

  void _showLyrics(BuildContext context) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭歌词',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (_, __, ___) => LyricsSheet(track: currentTrack),
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
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('播放列表'),
        content: SizedBox(
          width: 420,
          height: 360,
          child: ListView.separated(
            itemCount: tracks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (_, index) {
              final track = tracks[index];
              return ListTile(
                selected: index == _current,
                leading: _Art(color: track.color, size: 42, coverPath: track.coverPath),
                title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(track.artist),
                trailing: Text(track.duration),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_playIndex(index));
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar(
      {required this.page,
      required this.onBack,
      required this.onForward,
      required this.onSettings});
  final LibraryPage page;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final title = {
      LibraryPage.songs: '歌曲',
      LibraryPage.artists: '艺术家',
      LibraryPage.artistDetail: '艺术家详情',
      LibraryPage.albums: '专辑',
      LibraryPage.albumDetail: '专辑详情',
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
                  onPressed: page == LibraryPage.songs ? null : onBack,
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
      (LibraryPage.folders, Icons.folder_open_outlined, '文件夹')
    ];
    return AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: expanded ? 200 : 64,
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
                   child: Text('我的歌单', style: TextStyle(
                     fontSize: 11,
                     fontWeight: FontWeight.w700,
                     color: Theme.of(context).colorScheme.onSurfaceVariant,
                   )),
                 ),
                 IconButton(
                   tooltip: '新建歌单',
                   onPressed: onCreatePlaylist,
                   padding: EdgeInsets.zero,
                   constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                   icon: const Icon(Icons.add, size: 17),
                 ),
               ]),
             ),
             for (final entry in playlists.entries)
               _PlaylistNavItem(
                 name: entry.key,
                 color: entry.value.isEmpty ? Theme.of(context).colorScheme.primary : entry.value.first.color,
                  selected: selectedPlaylist == entry.key,
                 onTap: () => onPlaylist(entry.key),
               ),
           ] else
             _NavItem(
               icon: Icons.queue_music_outlined,
               label: '歌单',
               selected: page == LibraryPage.playlists || page == LibraryPage.playlistDetail,
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
              icon: Icons.warning_amber_outlined,
              label: '不可读曲目',
              selected: page == LibraryPage.unreadable,
              expanded: expanded,
              onTap: () => onSelect(LibraryPage.unreadable)),
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
                        transitionBuilder: (child, animation) =>
                            FadeTransition(
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
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
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
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      );
}

class SongsPage extends StatelessWidget {
  const SongsPage(
      {super.key,
      required this.query,
      required this.sort,
      required this.grid,
      required this.playing,
      required this.current,
      required this.onQuery,
      required this.onSort,
      required this.onGrid,
      required this.onPlay});
  final String query, sort;
  final bool grid, playing;
  final int current;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onSort;
  final VoidCallback onGrid;
  final ValueChanged<int> onPlay;
  @override
  Widget build(BuildContext context) {
    final shown = tracks
        .where((t) => PinyinUtils.matches(query, [t.title, t.artist, t.album, t.title]))
        .toList();
    shown.sort((a, b) {
      switch (sort) {
        case '标题 A-Z': return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case '标题 Z-A': return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case '艺术家': return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        case '专辑': return a.album.toLowerCase().compareTo(b.album.toLowerCase());
        case '时长': return a.duration.compareTo(b.duration);
        case '文件名': return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        default: return 0;
      }
    });
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
              Text('${tracks.length} 首歌曲 · 42 分钟',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant))
            ]),
            const Spacer(),
            FilledButton.icon(
                onPressed: () => onPlay(0),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('全部播放')),
            const SizedBox(width: 9),
            OutlinedButton.icon(
                onPressed: () => onPlay(DateTime.now().millisecondsSinceEpoch % tracks.length),
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('随机播放'))
          ]),
          const SizedBox(height: 22),
          Row(children: [
            DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                    value: sort,
                    borderRadius: BorderRadius.circular(8),
                    items: const ['手动', '添加时间', '标题 A-Z', '标题 Z-A', '艺术家', '专辑', '年份', '时长', '文件名']
                        .map((e) =>
                            DropdownMenuItem(value: e, child: Text('排序：$e')))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) onSort(v);
                    })),
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
                width: 210,
                height: 34,
                child: TextField(
                    onChanged: onQuery,
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: '筛选当前列表',
                        contentPadding: EdgeInsets.zero,
                        border: OutlineInputBorder())))
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: grid
                ? _TrackGrid(tracks: shown, onPlay: onPlay)
                : ListView.separated(
                    itemCount: shown.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 3),
                    itemBuilder: (context, index) {
                      final t = shown[index];
                      final realIndex = tracks.indexOf(t);
                      return _TrackRow(
                        track: t,
                        index: realIndex,
                        selected: playing && realIndex == current,
                        onPlay: () => onPlay(realIndex),
                        onInfo: () => showDialog<void>(
                          context: context,
                          builder: (_) => TrackInfoDialog(track: t),
                        ),
                      );
                    },
                  ),
          ),
        ]));
  }
}

class _TrackRow extends StatefulWidget {
  const _TrackRow(
      {required this.track,
      required this.index,
      required this.selected,
      required this.onPlay,
      required this.onInfo});
  final Track track;
  final int index;
  final bool selected;
  final VoidCallback onPlay, onInfo;
  @override
  State<_TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<_TrackRow> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: InkWell(
          onDoubleTap: widget.onPlay,
          onTap: widget.onPlay,
          onSecondaryTap: widget.onInfo,
          borderRadius: BorderRadius.circular(9),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: widget.selected
                  ? Theme.of(context).colorScheme.primary.withOpacity(.12)
                  : hover
                      ? Theme.of(context).colorScheme.onSurface.withOpacity(.05)
                      : null,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(children: [
              SizedBox(
                  width: 28,
                  child: Text(
                    '${widget.index + 1}'.padLeft(2, '0'),
                    style: TextStyle(
                      color: widget.selected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  )),
              _Art(color: widget.track.color, size: 48, coverPath: widget.track.coverPath),
              const SizedBox(width: 13),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${widget.track.artist}  ·  ${widget.track.album}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ])),
              const SizedBox(width: 12),
              Text(widget.track.format,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(width: 28),
              Text(widget.track.duration,
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
              SizedBox(
                  width: 34,
                  child: IconButton(
                      tooltip: '更多操作',
                      onPressed: widget.onInfo,
                      icon: const Icon(Icons.more_horiz, size: 19))),
            ]),
          ),
        ),
      );
}

class _TrackGrid extends StatelessWidget {
  const _TrackGrid({required this.tracks, required this.onPlay});
  final List<Track> tracks;
  final ValueChanged<int> onPlay;
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
            onTap: () => onPlay(stillTracks.indexOf(t)),
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
                    Text(t.artist,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ]),
            ),
          );
        },
      );
}

// A named view of the constant list keeps grid callbacks readable.
final stillTracks = tracks;

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
  final VoidCallback onPlay, onPrevious, onNext, onStop, onLyrics, onMute, onMode, onDesktopLyrics, onPlaylist;
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
    final progress = (position.inMilliseconds / duration).clamp(0, 1).toDouble();
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: 116,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withOpacity(.94),
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor.withOpacity(.45))),
          ),
          child: Stack(children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: progress,
                  min: 0,
                  max: 1,
                  onChanged: (value) => onSeek(Duration(milliseconds: (duration * value).round())),
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
                      child: Hero(tag: 'active-cover', child: _Art(color: track.color, size: 52, coverPath: track.coverPath)),
                    ),
                    const SizedBox(width: 12),
                    Flexible(child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ],
                    )),
                  ]),
                ),
                Expanded(
                  flex: 5,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(_formatDuration(position), style: Theme.of(context).textTheme.labelSmall),
                    const SizedBox(width: 8),
                    IconButton(tooltip: modeLabel, onPressed: onMode, icon: Icon(modeIcon, size: 19, color: mode == PlaybackMode.sequential ? null : Theme.of(context).colorScheme.primary)),
                    IconButton(tooltip: '上一首', onPressed: onPrevious, icon: const Icon(Icons.skip_previous, size: 23)),
                    IconButton.filled(tooltip: playing ? '暂停' : '播放', onPressed: onPlay, icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 22)),
                    IconButton(tooltip: '下一首', onPressed: onNext, icon: const Icon(Icons.skip_next, size: 23)),
                    IconButton(tooltip: '停止', onPressed: onStop, icon: const Icon(Icons.stop, size: 20)),
                    const SizedBox(width: 8),
                    Text(track.duration, style: Theme.of(context).textTheme.labelSmall),
                  ]),
                ),
                Expanded(
                  flex: 3,
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    IconButton(tooltip: '桌面歌词', onPressed: onDesktopLyrics, icon: Icon(Icons.subtitles_outlined, size: 20, color: desktopLyricsVisible ? Theme.of(context).colorScheme.primary : null)),
                    IconButton(tooltip: '倍速', onPressed: () => _speedDialog(context), icon: Text('${speed.toStringAsFixed(2)}x', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
                    IconButton(tooltip: '音量', onPressed: () => _volumeDialog(context), icon: Icon(muted || volume == 0 ? Icons.volume_off : Icons.volume_up, size: 20)),
                    IconButton(tooltip: '播放列表', onPressed: onPlaylist, icon: const Icon(Icons.queue_music, size: 20)),
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
    showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('音量控制'),
          content: SizedBox(
            width: 360,
            child: Row(children: [
              IconButton(tooltip: dialogMuted ? '取消静音' : '静音', onPressed: () { onMute(); dialogMuted = !dialogMuted; setDialogState(() {}); }, icon: Icon(dialogMuted ? Icons.volume_off : Icons.volume_up)),
              Expanded(child: Slider(value: dialogVolume, min: 0, max: 1, divisions: 100, label: '${(dialogVolume * 100).round()}%', onChanged: (value) { dialogVolume = value; onVolume(value); setDialogState(() {}); })),
              SizedBox(width: 48, child: Text('${(dialogVolume * 100).round()}%', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
        ),
      ),
    );
  }

  void _speedDialog(BuildContext context) {
    const presets = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    var dialogSpeed = speed;
    showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('播放倍速'),
          content: SizedBox(
              width: 360,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: Slider(value: dialogSpeed, min: .5, max: 2, divisions: 30, label: '${dialogSpeed.toStringAsFixed(2)}x', onChanged: (value) { dialogSpeed = value; onSpeed(value); setDialogState(() {}); })),
                SizedBox(width: 54, child: Text('${dialogSpeed.toStringAsFixed(2)}x', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [for (final preset in presets) ChoiceChip(label: Text('${preset}x'), selected: (dialogSpeed - preset).abs() < .01, onSelected: (_) { dialogSpeed = preset; onSpeed(preset); setDialogState(() {}); })]),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
        ),
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
  Widget build(BuildContext context) => Padding(
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
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisExtent: 210,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            itemCount: labels.length,
            itemBuilder: (_, i) => InkWell(
              onTap: () => onTap(labels[i]),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Expanded(
                        child: _Art(
                            color: Colors.primaries[i % Colors.primaries.length]
                                .withOpacity(.72),
                            size: 150),
                      ),
                      const SizedBox(height: 6),
                      Text(labels[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                          counts != null && i < counts!.length
                              ? counts![i]
                              : '${(i + 2) * 3} 首歌曲',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  )),
            ),
          )),
        ]),
      );
}

class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key, required this.folders, required this.onAdd, required this.onOpen});
  final List<String> folders;
  final VoidCallback onAdd;
  final ValueChanged<String> onOpen;
  @override
  Widget build(BuildContext context) => _SimplePage(
      title: '文件夹',
      action: '添加文件夹', actionCallback: onAdd,
      child: folders.isEmpty ? const Center(child: Text('尚未添加音乐文件夹')) : ListView(children: [for (final path in folders) FolderTile(path: path, songs: '扫描缓存 · 点击进入', onTap: () => onOpen(path))]));
}

class FolderTile extends StatelessWidget {
  const FolderTile({super.key, required this.path, required this.songs, this.onTap});
  final String path, songs;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      leading:
          const Icon(Icons.folder_rounded, size: 30, color: Color(0xffd5aa5b)),
      title: Text(path, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(songs),
      trailing: const Icon(Icons.chevron_right));
}

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key, required this.playlists, required this.onCreate, required this.onDelete, required this.onRename, required this.onOpen});
  final Map<String, List<Track>> playlists;
  final VoidCallback onCreate;
  final ValueChanged<String> onDelete;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onOpen;
  @override
  Widget build(BuildContext context) => _SimplePage(
      title: '歌单',
      action: '新建歌单', actionCallback: onCreate,
      child: ListView(children: [for (final e in playlists.entries) Dismissible(key: ValueKey(e.key), onDismissed: (_) => onDelete(e.key), child: ListTile(onTap: () => onOpen(e.key), leading: Icon(e.key == '我喜欢的音乐' ? Icons.favorite : Icons.queue_music, color: e.key == '我喜欢的音乐' ? const Color(0xffe57373) : null), title: Text(e.key), subtitle: Text('${e.value.length} 首'), trailing: PopupMenuButton<String>(onSelected: (v) { if (v == 'rename') onRename(e.key); if (v == 'delete') onDelete(e.key); }, itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('重命名')), PopupMenuItem(value: 'delete', child: Text('删除'))])))]));
}

class _SimplePage extends StatelessWidget {
  const _SimplePage(
      {required this.title, required this.action, required this.child, this.actionCallback});
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
            StatCard(label: '总时长', value: '${library.fold<int>(0, (s, t) => s + _durationSeconds(t.duration)) ~/ 60} 分钟'),
            StatCard(label: '艺术家', value: '${library.map((t) => t.artist).toSet().length}'),
            StatCard(label: '专辑', value: '${library.map((t) => t.album).toSet().length}'),
            StatCard(label: '总大小', value: '本地库'),
          ]),
          const SizedBox(height: 26),
          Text('格式分布',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          for (final format in ['FLAC', 'MP3', 'AAC', 'OGG']) _Bar(label: format, value: library.where((t) => t.format.startsWith(format)).length / (library.isEmpty ? 1 : library.length), count: '${library.where((t) => t.format.startsWith(format)).length} 首'),
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

int _durationSeconds(String value) { final p = value.split(':'); return p.length == 2 ? int.tryParse(p[0])! * 60 + int.tryParse(p[1])! : 0; }

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

class ArtistDetailPage extends StatelessWidget {
  const ArtistDetailPage({super.key, required this.artist, required this.onAlbum, required this.onPlay});
  final String artist; final ValueChanged<String> onAlbum; final ValueChanged<int> onPlay;
  @override Widget build(BuildContext context) {
    final songs = tracks.where((t) => t.artist == artist).toList();
    final albums = songs.map((t) => t.album).toSet().toList();
    return Padding(padding: const EdgeInsets.all(28), child: ListView(children: [Row(children: [_Art(color: Colors.teal, size: 160), const SizedBox(width: 22), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(artist, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)), Text('${albums.length} 张专辑 · ${songs.length} 首歌'), const SizedBox(height: 12), FilledButton.icon(onPressed: songs.isEmpty ? null : () => onPlay(0), icon: const Icon(Icons.play_arrow), label: const Text('全部播放'))])]), const SizedBox(height: 28), const Text('热门歌曲', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), ...songs.take(10).toList().asMap().entries.map((e) => ListTile(dense: true, leading: Text('${e.key + 1}'.padLeft(2, '0')), title: Text(e.value.title), trailing: Text(e.value.duration), onTap: () => onPlay(e.key))), const SizedBox(height: 16), const Text('专辑', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), Wrap(spacing: 16, children: [for (final album in albums) InkWell(onTap: () => onAlbum(album), child: SizedBox(width: 150, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_Art(color: Colors.primaries[albums.indexOf(album) % Colors.primaries.length], size: 130), const SizedBox(height: 6), Text(album, maxLines: 1, overflow: TextOverflow.ellipsis)])))]) ]));
  }
}

class AlbumDetailPage extends StatelessWidget {
  const AlbumDetailPage({super.key, required this.album, required this.onArtist, required this.onPlay});
  final String album; final ValueChanged<String> onArtist; final ValueChanged<int> onPlay;
  @override Widget build(BuildContext context) { final songs = tracks.where((t) => t.album == album).toList(); final artist = songs.isEmpty ? '' : songs.first.artist; final cover = songs.isNotEmpty ? songs.first.coverPath : ''; return Padding(padding: const EdgeInsets.all(28), child: ListView(children: [Row(children: [_Art(color: Colors.indigo, size: 200, coverPath: cover), const SizedBox(width: 22), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(album, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)), InkWell(onTap: () => onArtist(artist), child: Text(artist)), Text('${songs.length} 首歌 · ${songs.fold<int>(0, (s,t)=>s+_durationSeconds(t.duration)) ~/ 60} 分钟'), const SizedBox(height: 12), FilledButton.icon(onPressed: songs.isEmpty ? null : () => onPlay(0), icon: const Icon(Icons.play_arrow), label: const Text('全部播放'))])]), const SizedBox(height: 28), const Text('曲目', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), ...songs.asMap().entries.map((e) => ListTile(dense: true, leading: Text('${e.key + 1}'.padLeft(2,'0')), title: Text(e.value.title), subtitle: Text(e.value.artist), trailing: Text(e.value.duration), onTap: () => onPlay(e.key))) ])); }
}

class FolderDetailPage extends StatelessWidget {
  const FolderDetailPage({super.key, required this.path, required this.onBack, required this.onOpen});
  final String path; final VoidCallback onBack; final ValueChanged<String> onOpen;
  @override Widget build(BuildContext context) { final children = path.isEmpty ? <String>[] : path.split(Platform.pathSeparator); return Padding(padding: const EdgeInsets.all(28), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)), Expanded(child: Text(children.join(' / '), maxLines: 1, overflow: TextOverflow.ellipsis))]), const Divider(), Expanded(child: ListView(children: [for (final d in children.reversed.take(3)) ListTile(leading: const Icon(Icons.folder), title: Text(d), onTap: () => onOpen(d)), ...tracks.where((t) => t.path.isEmpty || t.path.startsWith(path)).map((t) => ListTile(leading: const Icon(Icons.music_note), title: Text(t.title), subtitle: Text(t.artist), trailing: Text(t.duration)))]))])); }
}

class PlaylistDetailPage extends StatelessWidget {
  const PlaylistDetailPage({super.key, required this.name, required this.songs, required this.onAdd, required this.onRemove, required this.onReorder});
  final String name; final List<Track> songs; final ValueChanged<Track> onAdd, onRemove; final void Function(int, int) onReorder;
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(28), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)), Text('${songs.length} 首歌曲')]), const Spacer(), PopupMenuButton<Track>(tooltip: '添加歌曲', icon: const Icon(Icons.add), onSelected: onAdd, itemBuilder: (_) => [for (final t in tracks) PopupMenuItem(value: t, child: Text(t.title))])]), const SizedBox(height: 18), Expanded(child: ReorderableListView.builder(itemCount: songs.length, onReorder: onReorder, itemBuilder: (_, i) { final t=songs[i]; return ListTile(key: ValueKey('${t.title}-$i'), leading: const Icon(Icons.drag_handle), title: Text(t.title), subtitle: Text(t.artist), trailing: IconButton(tooltip:'移除', icon: const Icon(Icons.remove_circle_outline), onPressed:()=>onRemove(t))); }))]));
}

class UnreadablePage extends StatelessWidget {
  const UnreadablePage({super.key, required this.items, required this.onRelink, required this.onRemove, required this.onRemoveAll});
  final Set<Track> items; final ValueChanged<Track> onRelink, onRemove; final VoidCallback onRemoveAll;
  @override Widget build(BuildContext context) => _SimplePage(title: '不可读曲目', action: '批量移除', actionCallback: onRemoveAll, child: items.isEmpty ? const Center(child: Text('没有不可读曲目')) : ListView(children: [for (final t in items) ListTile(leading: const Icon(Icons.warning_amber), title: Text(t.title), subtitle: Text(t.path.isEmpty ? t.album : t.path), trailing: Wrap(children: [IconButton(tooltip:'重新链接', icon: const Icon(Icons.link), onPressed:()=>onRelink(t)), IconButton(tooltip:'移除', icon: const Icon(Icons.delete_outline), onPressed:()=>onRemove(t))]))]));
}

class SettingsPage extends StatelessWidget {
  const SettingsPage(
      {super.key, required this.themeMode, required this.onThemeChanged});
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  @override
  Widget build(BuildContext context) => _SimplePage(
      title: '设置',
      action: '恢复默认',
      child: ListView(children: [
        Text('外观',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        RadioListTile<ThemeMode>(
            value: ThemeMode.dark,
            groupValue: themeMode,
            onChanged: (v) {
              if (v != null) onThemeChanged(v);
            },
            title: const Text('深色模式'),
            subtitle: const Text('更适合夜间聆听')),
        RadioListTile<ThemeMode>(
            value: ThemeMode.light,
            groupValue: themeMode,
            onChanged: (v) {
              if (v != null) onThemeChanged(v);
            },
            title: const Text('浅色模式')),
        const Divider(height: 30),
        Text('播放',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const _SettingsSwitch(title: '启动时恢复上次播放位置', initialValue: true),
        const _SettingsSwitch(title: '无缝播放', initialValue: false),
        const Divider(height: 30),
        Text('全屏歌词 · 歌词效果',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const _PersistentSwitch(
            title: '雪花粒子', prefKey: 'lyrics_snow', defaultValue: false),
        const _PersistentSwitch(
            title: '雾气效果', prefKey: 'lyrics_fog', defaultValue: false),
        const _PersistentSwitch(
            title: '雨滴效果', prefKey: 'lyrics_rain', defaultValue: false),
      ]));
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
  Widget build(BuildContext context) => SwitchListTile(value: value, onChanged: (next) => setState(() => value = next), title: Text(widget.title));
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

class TrackInfoDialog extends StatelessWidget {
  const TrackInfoDialog({super.key, required this.track});
  final Track track;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('歌曲属性'),
        content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _Art(color: track.color, size: 72, coverPath: track.coverPath),
                  const SizedBox(width: 14),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.title,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(track.artist),
                        Text(track.album,
                            style: Theme.of(context).textTheme.bodySmall),
                      ])
                ]),
                const Divider(height: 28),
                const _InfoLine('格式', 'FLAC'),
                const _InfoLine('码率', '1,024 kbps'),
                const _InfoLine('采样率', '44,100 Hz'),
                const _InfoLine('位深度', '24 bit'),
                const _InfoLine('声道', '立体声'),
                const _InfoLine('文件大小', '38.4 MB'),
                const _InfoLine('文件路径', r'D:\Music\Library\track.flac'),
                const _InfoLine('歌词来源', '内嵌歌词'),
                const _InfoLine('播放次数', '23 次'),
              ],
            ))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭'))
        ],
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
  const LyricsSheet({super.key, required this.track});
  final Track track;
  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  _LyricsDisplayMode _displayMode = _LyricsDisplayMode.lyrics;
  bool _translated = false;
  double _timeOffset = 0;
  final _scroll = ScrollController();
  Timer? _autoScroll;
  List<LyricLine> _lines = const [];
  int _activeLine = 0;
  bool _hudVisible = true;
  Timer? _hudTimer;
  bool _showCopyDialog = false;
  bool _showOffsetDialog = false;
  bool _showSettingsDialog = false;
  bool _showSourceMenu = false;
  double _fontSize = 22;
  double _translationFontSize = 14;
  FontWeight _fontWeight = FontWeight.w500;
  bool _snowEnabled = false;
  bool _fogEnabled = false;
  bool _rainEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadLyrics();
    _loadEffectSettings();
    _startAutoScroll();
    _startHudTimer();
  }

  Future<void> _loadEffectSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _snowEnabled = prefs.getBool('lyrics_snow') ?? false;
      _fogEnabled = prefs.getBool('lyrics_fog') ?? false;
      _rainEnabled = prefs.getBool('lyrics_rain') ?? false;
    });
  }

  void _startAutoScroll() {
    _autoScroll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _lines.isEmpty) return;
      setState(() => _activeLine = (_activeLine + 1) % _lines.length);
      if (_scroll.hasClients) {
        _scroll.animateTo(
          (_activeLine * 76.0).clamp(0.0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _startHudTimer() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  void _onPointerMove() {
    setState(() => _hudVisible = true);
    _startHudTimer();
  }

  Future<void> _loadLyrics() async {
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
  }

  @override
  void dispose() {
    _autoScroll?.cancel();
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
              icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 28),
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
                    style: TextStyle(color: Colors.white.withOpacity(.7), fontSize: 12),
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
            onTap: () => setState(() => _displayMode = _LyricsDisplayMode.lyrics),
          ),
          _ModeButton(
            icon: Icons.image_outlined,
            tooltip: '纯封面',
            active: _displayMode == _LyricsDisplayMode.cover,
            onTap: () => setState(() => _displayMode = _LyricsDisplayMode.cover),
          ),
          _ModeButton(
            icon: Icons.view_column_outlined,
            tooltip: '混合横屏',
            active: _displayMode == _LyricsDisplayMode.mixHorizontal,
            onTap: () => setState(() => _displayMode = _LyricsDisplayMode.mixHorizontal),
          ),
          _ModeButton(
            icon: Icons.view_agenda_outlined,
            tooltip: '混合竖屏',
            active: _displayMode == _LyricsDisplayMode.mixVertical,
            onTap: () => setState(() => _displayMode = _LyricsDisplayMode.mixVertical),
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
                  _AnimatedCoverArt(
                    size: coverSize,
                    color: widget.track.color,
                    borderRadius: mode == _LyricsDisplayMode.mixVertical ? 12 : 16,
                    coverPath: widget.track.coverPath,
                  ),
                  if (showCoverInfo && mode != _LyricsDisplayMode.mixVertical) ...[
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
                              fontSize: mode == _LyricsDisplayMode.cover ? 22 : 18,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.track.artist,
                            style: TextStyle(
                              color: Colors.white.withOpacity(.7),
                              fontSize: mode == _LyricsDisplayMode.cover ? 15 : 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (mode == _LyricsDisplayMode.mixHorizontal) ...[
                            const SizedBox(height: 4),
                            Text(
                              widget.track.album,
                              style: TextStyle(color: Colors.white.withOpacity(.5), fontSize: 12),
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
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.track.artist} · ${widget.track.album}',
                  style: TextStyle(color: Colors.white.withOpacity(.7), fontSize: 13),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLyricsList({required bool wide}) {
    return ListView.builder(
      controller: _scroll,
      itemCount: _lines.length,
      padding: EdgeInsets.symmetric(
        vertical: wide ? 80 : (_displayMode == _LyricsDisplayMode.lyrics ? 180 : 100),
        horizontal: wide ? 24 : 48,
      ),
      itemBuilder: (_, index) => _buildLyricLine(index, _fontSize, wide: wide),
    );
  }

  Widget _buildLyricLine(int index, double fontSize, {bool wide = false}) {
    final line = _lines[index];
    final active = index == _activeLine;
    final distance = (index - _activeLine).abs();
    final opacity = (1.0 - distance * 0.08).clamp(0.3, 1.0);
    final scale = (1.0 - distance * 0.02).clamp(0.88, 1.0);

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
          child: Column(
            crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                textAlign: wide ? TextAlign.left : TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(active ? 1.0 : opacity),
                  fontSize: active ? fontSize : fontSize * 0.95,
                  fontWeight: active ? FontWeight.w700 : _fontWeight,
                ),
                child: Text(line.text),
              ),
              if (_translated && line.translation != null) ...[
                const SizedBox(height: 4),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  textAlign: wide ? TextAlign.left : TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(active ? 0.5 : 0.3),
                    fontSize: _translationFontSize,
                    fontWeight: FontWeight.w400,
                  ),
                  child: Text(line.translation!),
                ),
              ],
            ],
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
                color: const Color(0xff1e2028),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 24)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('歌词源', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  _SourceItem(label: '内嵌歌词', type: LyricsSourceType.embedded),
                  const SizedBox(height: 8),
                  _SourceItem(label: '本地 LRC 文件', type: LyricsSourceType.localFile),
                  const SizedBox(height: 8),
                  _SourceItem(label: '在线搜索', type: LyricsSourceType.online),
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
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 24)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('复制歌词', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => setState(() => _showCopyDialog = false),
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
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.05),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(line.text, style: const TextStyle(color: Colors.white)),
                              if (line.translation != null)
                                Text(
                                  line.translation!,
                                  style: TextStyle(color: Colors.white.withOpacity(.5), fontSize: 12),
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
                            SnackBar(content: Text('已复制 ${_lines.length} 行歌词到剪贴板')),
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
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 24)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('歌词偏移', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  Text(
                    _formatOffset(_timeOffset),
                    style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700),
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
                        label: Text(_formatOffset(v), style: TextStyle(
                          color: _timeOffset == v ? Theme.of(context).colorScheme.primary : Colors.white70,
                        )),
                        onPressed: () => setState(() => _timeOffset = v),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _showOffsetDialog = false),
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
              width: 440,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7,
              ),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xff1e2028),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 24)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('歌词设置', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => setState(() => _showSettingsDialog = false),
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
                                icon: const Icon(Icons.remove, color: Colors.white70, size: 18),
                                onPressed: () => setState(() => _fontSize = (_fontSize - 2).clamp(14, 48)),
                              ),
                              SizedBox(
                                width: 48,
                                child: Text('${_fontSize.round()}px', style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add, color: Colors.white70, size: 18),
                                onPressed: () => setState(() => _fontSize = (_fontSize + 2).clamp(14, 48)),
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
                                icon: const Icon(Icons.remove, color: Colors.white70, size: 18),
                                onPressed: () => setState(() => _translationFontSize = (_translationFontSize - 1).clamp(10, 24)),
                              ),
                              SizedBox(
                                width: 48,
                                child: Text('${_translationFontSize.round()}px', style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add, color: Colors.white70, size: 18),
                                onPressed: () => setState(() => _translationFontSize = (_translationFontSize + 1).clamp(10, 24)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _SettingsRow(
                          label: '歌词字重',
                          child: DropdownButton<FontWeight>(
                            value: _fontWeight,
                            dropdownColor: const Color(0xff2a2d38),
                            style: const TextStyle(color: Colors.white),
                            underline: const SizedBox(),
                            isDense: true,
                            items: const [
                              DropdownMenuItem(value: FontWeight.w400, child: Text('常规')),
                              DropdownMenuItem(value: FontWeight.w500, child: Text('中等')),
                              DropdownMenuItem(value: FontWeight.w600, child: Text('半粗')),
                              DropdownMenuItem(value: FontWeight.w700, child: Text('粗体')),
                            ],
                            onChanged: (v) => setState(() => _fontWeight = v ?? FontWeight.w500),
                          ),
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
            color: active ? Theme.of(context).colorScheme.primary.withOpacity(.3) : Colors.white.withOpacity(.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: active ? Theme.of(context).colorScheme.primary : Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class _SourceItem extends StatelessWidget {
  const _SourceItem({required this.label, required this.type});
  final String label;
  final LyricsSourceType type;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.06),
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
            color: Colors.white54,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13))),
        ],
      ),
    );
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
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        child,
      ],
    );
  }
}
