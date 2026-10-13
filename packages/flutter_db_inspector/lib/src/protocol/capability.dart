/// Operations a database adapter may support. Clients hide everything an
/// adapter does not advertise.
enum DbCapability {
  /// Browse entities and rows.
  read,

  /// Server-side filtering with `filters`.
  filter,

  /// Server-side ordering with `sort`.
  sort,

  /// Free-text `search` across values.
  search,
  insert,
  update,
  delete,
  clear,

  /// Native query console (`query.execute`), e.g. SQL.
  sql,

  /// Detailed `schema.table` information (columns, keys, constraints).
  schema,
  indexes,
  transactions,
  export,
  import,
  liveChanges;

  String get wireName => name;

  /// Parses capability names, silently skipping ones from newer versions.
  static Set<DbCapability> parseAll(Iterable<String> names) => {
        for (final name in names)
          for (final c in DbCapability.values)
            if (c.name == name) c,
      };
}

/// How an engine organises data. Clients use it for terminology and layout
/// (Tables/Rows vs Collections/Objects vs Boxes/Entries); behaviour is driven
/// by [DbCapability], never by the engine name.
enum DbDataModel {
  /// Tables with typed columns and rows (SQLite, Drift, Floor, ...).
  relational,

  /// Collections of objects/documents (Isar, ObjectBox, Realm, Sembast, ...).
  document,

  /// Named stores of key → value entries (Hive, SharedPreferences, ...).
  keyValue;

  static DbDataModel fromWire(String? name) => values.firstWhere(
        (m) => m.name == name,
        orElse: () => DbDataModel.relational,
      );
}
