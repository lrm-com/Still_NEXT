import 'package:drift/drift.dart';

/// Schema kept deliberately independent from generated companions so the app
/// can use the same model while running with the lightweight preferences DB.
class Songs extends Table {
  IntColumn get id => integer()();
  TextColumn get path => text().unique()();
  TextColumn get title => text()();
  TextColumn get artist => text().withDefault(const Constant(''))();
  TextColumn get album => text().withDefault(const Constant(''))();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastModified => dateTime().nullable()();
}

class Folders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get path => text().unique()();
  DateTimeColumn get lastScannedAt => dateTime().nullable()();
}

class Lyrics extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get songId => integer()();
  TextColumn get content => text().nullable()();
  IntColumn get offsetMs => integer().withDefault(const Constant(0))();
}
