import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 轻量本地 HTTP 媒体服务器，用于绕过 just_audio_windows / WMF
/// 对本地文件路径（尤其含中文字符）的兼容性问题。
/// 通过 http://localhost:{port}/{encodedPath} 提供文件流。
class LocalMediaServer {
  static final LocalMediaServer instance = LocalMediaServer._();
  LocalMediaServer._();

  HttpServer? _server;
  int _port = 0;
  final _pathMap = <String, String>{}; // urlPath -> absolutePath

  int get port => _port;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handleRequest);
    print('[LocalMediaServer] Started on port $_port');
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    _pathMap.clear();
    await server?.close(force: true);
  }

  /// 将本地文件路径映射为可播放的 HTTP URI
  Uri fileToUri(String absolutePath) {
    final normalized = absolutePath.replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    final urlPath = '/$fileName';
    _pathMap[urlPath.toLowerCase()] = absolutePath;
    print('[LocalMediaServer] Mapped: $urlPath -> $absolutePath');
    return Uri.parse('http://127.0.0.1:$_port$urlPath');
  }

  void _handleRequest(HttpRequest request) {
    final rawPath = request.uri.path;
    final urlPath = Uri.decodeFull(rawPath);
    final lookupKey = urlPath.toLowerCase();
    print('[LocalMediaServer] Request: raw=$rawPath decoded=$urlPath');
    
    final filePath = _pathMap[lookupKey];
    if (filePath == null) {
      print('[LocalMediaServer] Path not found: $lookupKey');
      print('[LocalMediaServer] Available paths: ${_pathMap.keys.toList()}');
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      print('[LocalMediaServer] File not exists: $filePath');
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }

    print('[LocalMediaServer] Serving: $filePath');

    // 支持 Range 请求（just_audio 需要）
    final fileLength = file.lengthSync();
    final rangeHeader = request.headers.value('Range');

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      final start = int.tryParse(parts[0]) ?? 0;
      final end = parts.length > 1 && parts[1].isNotEmpty
          ? int.tryParse(parts[1]) ?? (fileLength - 1)
          : (fileLength - 1);
      final contentLength = end - start + 1;

      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers
          .set(HttpHeaders.contentTypeHeader, _mimeType(filePath));
      request.response.headers.set(HttpHeaders.contentLengthHeader, contentLength);
      request.response.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/$fileLength');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      file.openRead(start, end + 1).cast<List<int>>().pipe(request.response);
    } else {
      request.response.headers
          .set(HttpHeaders.contentTypeHeader, _mimeType(filePath));
      request.response.headers.set(HttpHeaders.contentLengthHeader, fileLength);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      file.openRead().cast<List<int>>().pipe(request.response);
    }
  }

  static String _mimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'mp3' => 'audio/mpeg',
      'flac' => 'audio/flac',
      'm4a' || 'aac' => 'audio/aac',
      'ogg' => 'audio/ogg',
      'wav' => 'audio/wav',
      'opus' => 'audio/opus',
      'ape' => 'audio/ape',
      'wma' => 'audio/x-ms-wma',
      'dsf' || 'dff' => 'audio/dsd',
      _ => 'application/octet-stream',
    };
  }
}
