import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'app_database.g.dart';

/// Users of the test app.
class Users extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get email => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BlobColumn get avatar => blob().nullable()();
}

/// Todo items owned by a user.
class Todos extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  IntColumn get userId => integer().nullable().references(Users, #id)();
}

/// A small, generated Drift database used by the adapter tests.
@DriftDatabase(tables: [Users, Todos])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 3;
}
