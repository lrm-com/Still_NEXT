import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:still/services/metadata_cache_service.dart';
import 'package:still/services/metadata_service.dart';
import 'package:still/services/scanner_service.dart';

void main() {
  test('scans dropped audio files and folders without duplicates', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('still-scanner-');
    addTearDown(() => directory.delete(recursive: true));
    final audioFile = File('${directory.path}${Platform.pathSeparator}track.mp3');
    await audioFile.writeAsBytes([0, 1, 2]);
    await File('${directory.path}${Platform.pathSeparator}ignore.txt')
        .writeAsString('not audio');

    final preferences = await SharedPreferences.getInstance();
    final scanner = ScannerService(
      metadata: MetadataService(reader: _emptyMetadata),
      cache: MetadataCacheService(preferences: preferences),
    );

    final songs = await scanner.scan([audioFile.path, directory.path]);

    expect(songs, hasLength(1));
    expect(songs.single.path, audioFile.path);
    expect(songs.single.title, 'track');
  });
}

Future<Map<String, Object?>> _emptyMetadata(File file) async =>
    const <String, Object?>{};
