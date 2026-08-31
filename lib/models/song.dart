class Song {
  const Song({
    required this.id,
    required this.path,
    required this.title,
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.genre = '',
    this.year,
    this.trackNumber,
    this.duration = Duration.zero,
    this.fileSize = 0,
    this.format = '',
    this.bitrate,
    this.embeddedLyrics,
    this.coverArtPath,
    this.addedAt,
    this.lastModified,
  });

  final int id;
  final String path;
  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final String genre;
  final int? year;
  final int? trackNumber;
  final Duration duration;
  final int fileSize;
  final String format;
  final int? bitrate;
  final String? embeddedLyrics;
  final String? coverArtPath;
  final DateTime? addedAt;
  final DateTime? lastModified;

  String get fileName => path.split(RegExp(r'[\\/]')).last;

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'albumArtist': albumArtist,
        'genre': genre,
        'year': year,
        'trackNumber': trackNumber,
        'durationMs': duration.inMilliseconds,
        'fileSize': fileSize,
        'format': format,
        'bitrate': bitrate,
        'embeddedLyrics': embeddedLyrics,
        'coverArtPath': coverArtPath,
        'addedAt': addedAt?.toIso8601String(),
        'lastModified': lastModified?.toIso8601String(),
      };

  factory Song.fromJson(Map<String, Object?> json) => Song(
        id: json['id'] as int,
        path: json['path'] as String,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        albumArtist: json['albumArtist'] as String? ?? '',
        genre: json['genre'] as String? ?? '',
        year: json['year'] as int?,
        trackNumber: json['trackNumber'] as int?,
        duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
        fileSize: json['fileSize'] as int? ?? 0,
        format: json['format'] as String? ?? '',
        bitrate: json['bitrate'] as int?,
        embeddedLyrics: json['embeddedLyrics'] as String?,
        coverArtPath: json['coverArtPath'] as String?,
        addedAt: _date(json['addedAt']),
        lastModified: _date(json['lastModified']),
      );

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}
