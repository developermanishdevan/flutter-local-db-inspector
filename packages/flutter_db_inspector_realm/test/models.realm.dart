// dart format width=80
// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// RealmObjectGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: type=lint
class Person extends _Person with RealmEntity, RealmObjectBase, RealmObject {
  Person(
    int id,
    String name,
    bool isActive,
    double score, {
    String? email,
    DateTime? createdAt,
    Uint8List? avatar,
    Iterable<String> tags = const [],
    Address? address,
    Person? bestFriend,
    Map<String, int> counters = const {},
  }) {
    RealmObjectBase.set(this, 'id', id);
    RealmObjectBase.set(this, 'name', name);
    RealmObjectBase.set(this, 'email', email);
    RealmObjectBase.set(this, 'isActive', isActive);
    RealmObjectBase.set(this, 'score', score);
    RealmObjectBase.set(this, 'createdAt', createdAt);
    RealmObjectBase.set(this, 'avatar', avatar);
    RealmObjectBase.set<RealmList<String>>(
        this, 'tags', RealmList<String>(tags));
    RealmObjectBase.set(this, 'address', address);
    RealmObjectBase.set(this, 'bestFriend', bestFriend);
    RealmObjectBase.set<RealmMap<int>>(
        this, 'counters', RealmMap<int>(counters));
  }

  Person._();

  @override
  int get id => RealmObjectBase.get<int>(this, 'id') as int;
  @override
  set id(int value) => RealmObjectBase.set(this, 'id', value);

  @override
  String get name => RealmObjectBase.get<String>(this, 'name') as String;
  @override
  set name(String value) => RealmObjectBase.set(this, 'name', value);

  @override
  String? get email => RealmObjectBase.get<String>(this, 'email') as String?;
  @override
  set email(String? value) => RealmObjectBase.set(this, 'email', value);

  @override
  bool get isActive => RealmObjectBase.get<bool>(this, 'isActive') as bool;
  @override
  set isActive(bool value) => RealmObjectBase.set(this, 'isActive', value);

  @override
  double get score => RealmObjectBase.get<double>(this, 'score') as double;
  @override
  set score(double value) => RealmObjectBase.set(this, 'score', value);

  @override
  DateTime? get createdAt =>
      RealmObjectBase.get<DateTime>(this, 'createdAt') as DateTime?;
  @override
  set createdAt(DateTime? value) =>
      RealmObjectBase.set(this, 'createdAt', value);

  @override
  Uint8List? get avatar =>
      RealmObjectBase.get<Uint8List>(this, 'avatar') as Uint8List?;
  @override
  set avatar(Uint8List? value) => RealmObjectBase.set(this, 'avatar', value);

  @override
  RealmList<String> get tags =>
      RealmObjectBase.get<String>(this, 'tags') as RealmList<String>;
  @override
  set tags(covariant RealmList<String> value) =>
      throw RealmUnsupportedSetError();

  @override
  Address? get address =>
      RealmObjectBase.get<Address>(this, 'address') as Address?;
  @override
  set address(covariant Address? value) =>
      RealmObjectBase.set(this, 'address', value);

  @override
  Person? get bestFriend =>
      RealmObjectBase.get<Person>(this, 'bestFriend') as Person?;
  @override
  set bestFriend(covariant Person? value) =>
      RealmObjectBase.set(this, 'bestFriend', value);

  @override
  RealmMap<int> get counters =>
      RealmObjectBase.get<int>(this, 'counters') as RealmMap<int>;
  @override
  set counters(covariant RealmMap<int> value) =>
      throw RealmUnsupportedSetError();

  @override
  Stream<RealmObjectChanges<Person>> get changes =>
      RealmObjectBase.getChanges<Person>(this);

  @override
  Stream<RealmObjectChanges<Person>> changesFor([List<String>? keyPaths]) =>
      RealmObjectBase.getChangesFor<Person>(this, keyPaths);

  @override
  Person freeze() => RealmObjectBase.freezeObject<Person>(this);

  EJsonValue toEJson() {
    return <String, dynamic>{
      'id': id.toEJson(),
      'name': name.toEJson(),
      'email': email.toEJson(),
      'isActive': isActive.toEJson(),
      'score': score.toEJson(),
      'createdAt': createdAt.toEJson(),
      'avatar': avatar.toEJson(),
      'tags': tags.toEJson(),
      'address': address.toEJson(),
      'bestFriend': bestFriend.toEJson(),
      'counters': counters.toEJson(),
    };
  }

  static EJsonValue _toEJson(Person value) => value.toEJson();
  static Person _fromEJson(EJsonValue ejson) {
    if (ejson is! Map<String, dynamic>) return raiseInvalidEJson(ejson);
    return switch (ejson) {
      {
        'id': EJsonValue id,
        'name': EJsonValue name,
        'isActive': EJsonValue isActive,
        'score': EJsonValue score,
      } =>
        Person(
          fromEJson(id),
          fromEJson(name),
          fromEJson(isActive),
          fromEJson(score),
          email: fromEJson(ejson['email']),
          createdAt: fromEJson(ejson['createdAt']),
          avatar: fromEJson(ejson['avatar']),
          tags: fromEJson(ejson['tags']),
          address: fromEJson(ejson['address']),
          bestFriend: fromEJson(ejson['bestFriend']),
          counters: fromEJson(ejson['counters']),
        ),
      _ => raiseInvalidEJson(ejson),
    };
  }

  static final schema = () {
    RealmObjectBase.registerFactory(Person._);
    register(_toEJson, _fromEJson);
    return const SchemaObject(ObjectType.realmObject, Person, 'Person', [
      SchemaProperty('id', RealmPropertyType.int, primaryKey: true),
      SchemaProperty('name', RealmPropertyType.string,
          indexType: RealmIndexType.regular),
      SchemaProperty('email', RealmPropertyType.string, optional: true),
      SchemaProperty('isActive', RealmPropertyType.bool),
      SchemaProperty('score', RealmPropertyType.double),
      SchemaProperty('createdAt', RealmPropertyType.timestamp, optional: true),
      SchemaProperty('avatar', RealmPropertyType.binary, optional: true),
      SchemaProperty('tags', RealmPropertyType.string,
          collectionType: RealmCollectionType.list),
      SchemaProperty('address', RealmPropertyType.object,
          optional: true, linkTarget: 'Address'),
      SchemaProperty('bestFriend', RealmPropertyType.object,
          optional: true, linkTarget: 'Person'),
      SchemaProperty('counters', RealmPropertyType.int,
          collectionType: RealmCollectionType.map),
    ]);
  }();

  @override
  SchemaObject get objectSchema => RealmObjectBase.getSchema(this) ?? schema;
}

class Address extends _Address
    with RealmEntity, RealmObjectBase, EmbeddedObject {
  Address(
    String city, {
    String? zip,
  }) {
    RealmObjectBase.set(this, 'city', city);
    RealmObjectBase.set(this, 'zip', zip);
  }

  Address._();

  @override
  String get city => RealmObjectBase.get<String>(this, 'city') as String;
  @override
  set city(String value) => RealmObjectBase.set(this, 'city', value);

  @override
  String? get zip => RealmObjectBase.get<String>(this, 'zip') as String?;
  @override
  set zip(String? value) => RealmObjectBase.set(this, 'zip', value);

  @override
  Stream<RealmObjectChanges<Address>> get changes =>
      RealmObjectBase.getChanges<Address>(this);

  @override
  Stream<RealmObjectChanges<Address>> changesFor([List<String>? keyPaths]) =>
      RealmObjectBase.getChangesFor<Address>(this, keyPaths);

  @override
  Address freeze() => RealmObjectBase.freezeObject<Address>(this);

  EJsonValue toEJson() {
    return <String, dynamic>{
      'city': city.toEJson(),
      'zip': zip.toEJson(),
    };
  }

  static EJsonValue _toEJson(Address value) => value.toEJson();
  static Address _fromEJson(EJsonValue ejson) {
    if (ejson is! Map<String, dynamic>) return raiseInvalidEJson(ejson);
    return switch (ejson) {
      {
        'city': EJsonValue city,
      } =>
        Address(
          fromEJson(city),
          zip: fromEJson(ejson['zip']),
        ),
      _ => raiseInvalidEJson(ejson),
    };
  }

  static final schema = () {
    RealmObjectBase.registerFactory(Address._);
    register(_toEJson, _fromEJson);
    return const SchemaObject(ObjectType.embeddedObject, Address, 'Address', [
      SchemaProperty('city', RealmPropertyType.string),
      SchemaProperty('zip', RealmPropertyType.string, optional: true),
    ]);
  }();

  @override
  SchemaObject get objectSchema => RealmObjectBase.getSchema(this) ?? schema;
}

class Note extends _Note with RealmEntity, RealmObjectBase, RealmObject {
  static var _defaultsSet = false;

  Note(
    ObjectId id,
    String text, {
    Decimal128? amount,
    Uuid? token,
    RealmValue extra = const RealmValue.nullValue(),
  }) {
    if (!_defaultsSet) {
      _defaultsSet = RealmObjectBase.setDefaults<Note>({
        'extra': const RealmValue.nullValue(),
      });
    }
    RealmObjectBase.set(this, 'id', id);
    RealmObjectBase.set(this, 'text', text);
    RealmObjectBase.set(this, 'amount', amount);
    RealmObjectBase.set(this, 'token', token);
    RealmObjectBase.set(this, 'extra', extra);
  }

  Note._();

  @override
  ObjectId get id => RealmObjectBase.get<ObjectId>(this, 'id') as ObjectId;
  @override
  set id(ObjectId value) => RealmObjectBase.set(this, 'id', value);

  @override
  String get text => RealmObjectBase.get<String>(this, 'text') as String;
  @override
  set text(String value) => RealmObjectBase.set(this, 'text', value);

  @override
  Decimal128? get amount =>
      RealmObjectBase.get<Decimal128>(this, 'amount') as Decimal128?;
  @override
  set amount(Decimal128? value) => RealmObjectBase.set(this, 'amount', value);

  @override
  Uuid? get token => RealmObjectBase.get<Uuid>(this, 'token') as Uuid?;
  @override
  set token(Uuid? value) => RealmObjectBase.set(this, 'token', value);

  @override
  RealmValue get extra =>
      RealmObjectBase.get<RealmValue>(this, 'extra') as RealmValue;
  @override
  set extra(RealmValue value) => RealmObjectBase.set(this, 'extra', value);

  @override
  Stream<RealmObjectChanges<Note>> get changes =>
      RealmObjectBase.getChanges<Note>(this);

  @override
  Stream<RealmObjectChanges<Note>> changesFor([List<String>? keyPaths]) =>
      RealmObjectBase.getChangesFor<Note>(this, keyPaths);

  @override
  Note freeze() => RealmObjectBase.freezeObject<Note>(this);

  EJsonValue toEJson() {
    return <String, dynamic>{
      'id': id.toEJson(),
      'text': text.toEJson(),
      'amount': amount.toEJson(),
      'token': token.toEJson(),
      'extra': extra.toEJson(),
    };
  }

  static EJsonValue _toEJson(Note value) => value.toEJson();
  static Note _fromEJson(EJsonValue ejson) {
    if (ejson is! Map<String, dynamic>) return raiseInvalidEJson(ejson);
    return switch (ejson) {
      {
        'id': EJsonValue id,
        'text': EJsonValue text,
      } =>
        Note(
          fromEJson(id),
          fromEJson(text),
          amount: fromEJson(ejson['amount']),
          token: fromEJson(ejson['token']),
          extra: fromEJson(ejson['extra'],
              defaultValue: const RealmValue.nullValue()),
        ),
      _ => raiseInvalidEJson(ejson),
    };
  }

  static final schema = () {
    RealmObjectBase.registerFactory(Note._);
    register(_toEJson, _fromEJson);
    return const SchemaObject(ObjectType.realmObject, Note, 'Note', [
      SchemaProperty('id', RealmPropertyType.objectid, primaryKey: true),
      SchemaProperty('text', RealmPropertyType.string),
      SchemaProperty('amount', RealmPropertyType.decimal128, optional: true),
      SchemaProperty('token', RealmPropertyType.uuid, optional: true),
      SchemaProperty('extra', RealmPropertyType.mixed, optional: true),
    ]);
  }();

  @override
  SchemaObject get objectSchema => RealmObjectBase.getSchema(this) ?? schema;
}

class LogEntry extends _LogEntry
    with RealmEntity, RealmObjectBase, RealmObject {
  LogEntry(
    String message,
    int level,
  ) {
    RealmObjectBase.set(this, 'message', message);
    RealmObjectBase.set(this, 'level', level);
  }

  LogEntry._();

  @override
  String get message => RealmObjectBase.get<String>(this, 'message') as String;
  @override
  set message(String value) => RealmObjectBase.set(this, 'message', value);

  @override
  int get level => RealmObjectBase.get<int>(this, 'level') as int;
  @override
  set level(int value) => RealmObjectBase.set(this, 'level', value);

  @override
  Stream<RealmObjectChanges<LogEntry>> get changes =>
      RealmObjectBase.getChanges<LogEntry>(this);

  @override
  Stream<RealmObjectChanges<LogEntry>> changesFor([List<String>? keyPaths]) =>
      RealmObjectBase.getChangesFor<LogEntry>(this, keyPaths);

  @override
  LogEntry freeze() => RealmObjectBase.freezeObject<LogEntry>(this);

  EJsonValue toEJson() {
    return <String, dynamic>{
      'message': message.toEJson(),
      'level': level.toEJson(),
    };
  }

  static EJsonValue _toEJson(LogEntry value) => value.toEJson();
  static LogEntry _fromEJson(EJsonValue ejson) {
    if (ejson is! Map<String, dynamic>) return raiseInvalidEJson(ejson);
    return switch (ejson) {
      {
        'message': EJsonValue message,
        'level': EJsonValue level,
      } =>
        LogEntry(
          fromEJson(message),
          fromEJson(level),
        ),
      _ => raiseInvalidEJson(ejson),
    };
  }

  static final schema = () {
    RealmObjectBase.registerFactory(LogEntry._);
    register(_toEJson, _fromEJson);
    return const SchemaObject(ObjectType.realmObject, LogEntry, 'LogEntry', [
      SchemaProperty('message', RealmPropertyType.string),
      SchemaProperty('level', RealmPropertyType.int),
    ]);
  }();

  @override
  SchemaObject get objectSchema => RealmObjectBase.getSchema(this) ?? schema;
}
