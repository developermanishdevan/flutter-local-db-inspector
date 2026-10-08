import 'package:objectbox/objectbox.dart';

/// Test entity covering ints, nullable fields, dates, lists and an index.
@Entity()
class Task {
  Task({
    this.id = 0,
    required this.title,
    this.priority,
    this.done = false,
    this.due,
    this.tags = const [],
  });

  @Id()
  int id;

  @Index()
  String title;

  int? priority;

  bool done;

  @Property(type: PropertyType.date)
  DateTime? due;

  List<String> tags;

  Map<String, Object?> toJson() => {
        'title': title,
        'priority': priority,
        'done': done,
        'due': due?.toUtc(),
        'tags': tags,
      };

  static Task fromJson(Map<String, Object?> json) => Task(
        id: json['id'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        priority: json['priority'] as int?,
        done: json['done'] as bool? ?? false,
        due: json['due'] as DateTime?,
        tags: [for (final t in json['tags'] as List? ?? const []) '$t'],
      );
}
