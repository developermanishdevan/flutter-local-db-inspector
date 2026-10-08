import 'package:isar_community/isar.dart';

part 'models.g.dart';

/// Test model with an index, nullable fields, a list, an enum and an
/// embedded object.
@collection
class Person {
  Id id = Isar.autoIncrement;

  @Index()
  late String name;

  int? age;

  double? score;

  bool active = true;

  DateTime? birthday;

  List<String> tags = [];

  @enumerated
  Mood mood = Mood.calm;

  Address? address;
}

enum Mood { calm, happy, angry }

@embedded
class Address {
  String? city;
  String? zip;
  DateTime? since;
}

/// A second collection with a custom id name and a unique composite index.
@Collection(accessor: 'notes')
class Note {
  Id noteId = Isar.autoIncrement;

  @Index(
    name: 'title_author',
    composite: [CompositeIndex('author')],
    unique: true,
  )
  late String title;

  String? author;
}
