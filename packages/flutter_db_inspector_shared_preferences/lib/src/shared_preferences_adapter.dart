import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_preferences_store.dart';

/// Inspects SharedPreferences as a single key/value entity named
/// `shared_preferences`.
///
/// ```dart
/// SharedPreferencesAdapter(await SharedPreferences.getInstance());
/// SharedPreferencesAdapter.async(SharedPreferencesAsync());
/// SharedPreferencesAdapter.withCache(
///   await SharedPreferencesWithCache.create(cacheOptions: options),
/// );
/// ```
///
/// Every request first calls [SharedPreferencesStore.refresh], so the
/// snapshot kept for [SharedPreferencesAsync] (whose reads are asynchronous
/// while [KeyValueStore.keys] is not) is current.
class SharedPreferencesAdapter extends KeyValueAdapter {
  /// Inspects the legacy [SharedPreferences] API.
  SharedPreferencesAdapter(SharedPreferences prefs)
      : this.fromStore(SharedPreferencesStore.legacy(prefs));

  /// Inspects [SharedPreferencesAsync], optionally limited to [allowList].
  SharedPreferencesAdapter.async(
    SharedPreferencesAsync prefs, {
    Set<String>? allowList,
  }) : this.fromStore(
            SharedPreferencesStore.async(prefs, allowList: allowList));

  /// Inspects [SharedPreferencesWithCache].
  SharedPreferencesAdapter.withCache(SharedPreferencesWithCache prefs)
      : this.fromStore(SharedPreferencesStore.withCache(prefs));

  /// Inspects a preconfigured [store] (e.g. with a custom name).
  SharedPreferencesAdapter.fromStore(this.store)
      : super(type: 'shared_preferences', stores: () => [store]);

  /// The single store exposed by this adapter.
  final SharedPreferencesStore store;

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
