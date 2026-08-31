import 'dart:convert';
import 'dart:io';

class LastFmTrack {
  const LastFmTrack({required this.name, required this.artist, this.album, this.url, this.listeners});
  final String name;
  final String artist;
  final String? album;
  final String? url;
  final int? listeners;
  factory LastFmTrack.fromJson(Map<String, dynamic> json) => LastFmTrack(
        name: json['name'] as String? ?? '',
        artist: (json['artist'] is Map ? json['artist']['name'] : json['artist']) as String? ?? '',
        album: (json['album'] is Map ? json['album']['title'] : json['album']) as String?,
        url: json['url'] as String?,
        listeners: int.tryParse('${json['listeners'] ?? ''}'),
      );
}

typedef LastFmRequest = Future<Map<String, dynamic>> Function(Uri uri);

class LastFmService {
  LastFmService({required this.apiKey, this.sharedSecret, LastFmRequest? request})
      : _request = request ?? _httpRequest;
  final String apiKey;
  final String? sharedSecret;
  final LastFmRequest _request;

  Future<LastFmTrack?> trackInfo({required String artist, required String title, String? username}) async {
    final json = await _call('track.getInfo', {'artist': artist, 'track': title, if (username != null) 'username': username});
    final track = json['track'];
    return track is Map ? LastFmTrack.fromJson(Map<String, dynamic>.from(track)) : null;
  }

  Future<List<LastFmTrack>> search({required String artist, required String title, int limit = 20}) async {
    final json = await _call('track.search', {'artist': artist, 'track': title, 'limit': '$limit'});
    final matches = json['results']?['trackmatches']?['track'];
    if (matches is List) return List.unmodifiable(matches.whereType<Map>().map((e) => LastFmTrack.fromJson(Map<String, dynamic>.from(e))));
    if (matches is Map) return [LastFmTrack.fromJson(Map<String, dynamic>.from(matches))];
    return const [];
  }

  Future<void> updateNowPlaying({required String artist, required String title, String? album, String? username, String? sessionKey}) =>
      _call('track.updateNowPlaying', {'artist': artist, 'track': title, if (album != null) 'album': album, if (username != null) 'username': username, if (sessionKey != null) 'sk': sessionKey}).then((_) {});

  Future<void> scrobble({required String artist, required String title, required DateTime startedAt, String? album, String? sessionKey}) =>
      _call('track.scrobble', {'artist': artist, 'track': title, 'timestamp': '${startedAt.millisecondsSinceEpoch ~/ 1000}', if (album != null) 'album': album, if (sessionKey != null) 'sk': sessionKey}).then((_) {});

  Future<Map<String, dynamic>> _call(String method, Map<String, String> params) async {
    final query = <String, String>{'method': method, 'api_key': apiKey, 'format': 'json', ...params};
    return _request(Uri.https('ws.audioscrobbler.com', '/2.0/', query));
  }

  static Future<Map<String, dynamic>> _httpRequest(Uri uri) async {
    final client = HttpClient();
    try {
      final response = await client.getUrl(uri).then((request) => request.close());
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (response.statusCode < 200 || response.statusCode >= 300) throw HttpException('Last.fm request failed (${response.statusCode})');
      if (json is! Map) throw const FormatException('Invalid Last.fm response');
      if (json['error'] != null) throw StateError('${json['message'] ?? 'Last.fm error'}');
      return Map<String, dynamic>.from(json);
    } finally {
      client.close(force: true);
    }
  }
}
