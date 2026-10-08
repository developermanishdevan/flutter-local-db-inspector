import 'dart:typed_data';

import 'package:realm_dart/realm.dart';

part 'models.realm.dart';

@RealmModel()
class _Person {
  @PrimaryKey()
  late int id;

  @Indexed()
  late String name;

  String? email;
  late bool isActive;
  late double score;
  DateTime? createdAt;
  Uint8List? avatar;
  late List<String> tags;
  _Address? address;
  _Person? bestFriend;
  late Map<String, int> counters;
}

@RealmModel(ObjectType.embeddedObject)
class _Address {
  late String city;
  String? zip;
}

@RealmModel()
class _Note {
  @PrimaryKey()
  late ObjectId id;

  late String text;
  Decimal128? amount;
  Uuid? token;
  RealmValue extra = const RealmValue.nullValue();
}

/// No primary key: read-only in the inspector.
@RealmModel()
class _LogEntry {
  late String message;
  late int level;
}
