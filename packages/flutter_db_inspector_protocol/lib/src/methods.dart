/// Protocol method names.
abstract final class Methods {
  static const inspectorStatus = 'inspector.status';

  static const databaseList = 'database.list';
  static const databaseInfo = 'database.info';
  static const databaseStats = 'database.stats';

  static const schemaList = 'schema.list';
  static const schemaTable = 'schema.table';

  static const rowsQuery = 'rows.query';
  static const rowsCount = 'rows.count';

  static const rowInsert = 'row.insert';
  static const rowUpdate = 'row.update';
  static const rowDelete = 'row.delete';

  static const tableClear = 'table.clear';

  static const queryExecute = 'query.execute';

  static const valueRead = 'value.read';
}
