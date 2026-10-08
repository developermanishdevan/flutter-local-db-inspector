import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_store.dart';

/// Inspects [FlutterSecureStorage] as a single key/value entity named
/// `secure_storage`.
///
/// Values are masked unless [revealValues] is `true`; see
/// [SecureStorageStore]. Keys are reloaded at the start of every request.
class SecureStorageAdapter extends KeyValueAdapter {
  SecureStorageAdapter(
    FlutterSecureStorage storage, {
    bool revealValues = false,
  }) : this.fromStore(
          SecureStorageStore(storage, revealValues: revealValues),
        );

  /// Inspects a preconfigured [store] (e.g. with a custom name).
  SecureStorageAdapter.fromStore(this.store)
      : super(type: 'secure_storage', stores: () => [store]);

  /// The single store exposed by this adapter.
  final SecureStorageStore store;

  @override
  Future<SchemaOverview> getSchemaOverview() async {
    await store.refresh();
    return super.getSchemaOverview();
  }

  @override
  Future<RowsPage> queryRows(RowsQuery query) async {
    await store.refresh();
    return super.queryRows(query);
  }

  @override
  Future<int> countRows(RowsQuery query) async {
    await store.refresh();
    return super.countRows(query);
  }

  @override
  Future<MutationResult> insertRow(
    String table,
    Map<String, Object?> values,
  ) async {
    await store.refresh();
    return super.insertRow(table, values);
  }

  @override
  Future<MutationResult> updateRow(
    String table,
    RowKey key,
    Map<String, Object?> values,
  ) async {
    await store.refresh();
    return super.updateRow(table, key, values);
  }

  @override
  Future<MutationResult> deleteRow(String table, RowKey key) async {
    await store.refresh();
    return super.deleteRow(table, key);
  }

  @override
  Future<MutationResult> clearTable(String table) async {
    await store.refresh();
    return super.clearTable(table);
  }

  @override
  Future<ValueChunk> readValue(ValueRef ref) async {
    await store.refresh();
    return super.readValue(ref);
  }
}
