import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import 'query_history.dart';
import 'sql_controller.dart';
import 'table_controller.dart';
import 'wording.dart';

/// Main area tabs.
enum InspectorTab { data, schema, sql, stats }

/// A database in the sidebar tree with its lazily loaded schema overview.
class DatabaseNode {
  DatabaseNode(this.descriptor);

  final DatabaseDescriptor descriptor;
  SchemaOverview? overview;
  bool loading = false;
  String? error;

  String get id => descriptor.id;

  EntitySummary? entity(String name) =>
      overview?.entities.where((e) => e.name == name).firstOrNull;
}

/// Application state of the extension: databases, selection, tabs and the
/// per-entity / per-database controllers. Talks to the app only through
/// [InspectorClient].
class InspectorController extends ChangeNotifier {
  InspectorController({
    required this.client,
    required ValueListenable<ConnectionSnapshot> connection,
    required Stream<void> databasesChanged,
    QueryHistory? history,
  })  : _connection = connection,
        history = history ?? QueryHistory() {
    _connection.addListener(_onConnectionChanged);
    _databasesSubscription =
        databasesChanged.listen((_) => unawaited(loadDatabases()));
    _onConnectionChanged();
  }

  final InspectorClient client;
  final QueryHistory history;
  final ValueListenable<ConnectionSnapshot> _connection;
  late final StreamSubscription<void> _databasesSubscription;

  List<DatabaseNode> _databases = const [];
  bool _loadingDatabases = false;
  String? _databasesError;
  String? _selectedDatabaseId;
  String? _selectedEntity;
  InspectorTab _tab = InspectorTab.data;
  final _expansion = <String, bool>{};
  TableController? _table;
  final _sql = <String, SqlController>{};
  int _loadSeq = 0;
  int _generation = 0;
  bool _wasConnected = false;
  bool _disposed = false;

  ConnectionSnapshot get connection => _connection.value;
  bool get isConnected => _connection.value.isConnected;

  List<DatabaseNode> get databases => _databases;
  bool get loadingDatabases => _loadingDatabases;
  String? get databasesError => _databasesError;

  /// Bumped whenever data was reloaded after a (re)connection, so pages
  /// holding their own data (statistics) reload too.
  int get generation => _generation;

  InspectorLimits get limits =>
      _connection.value.status?.limits ?? const InspectorLimits();

  DatabaseNode? get selectedDatabase =>
      _databases.where((d) => d.id == _selectedDatabaseId).firstOrNull;

  String? get selectedEntityName => _selectedEntity;

  EntitySummary? get selectedEntity {
    final name = _selectedEntity;
    return name == null ? null : selectedDatabase?.entity(name);
  }

  InspectorTab get tab => _tab;

  /// Controller of the selected entity's Data/Schema tabs.
  TableController? get table => _table;

  /// Whether a tree node is expanded ([byDefault] until the user toggles
  /// it).
  bool isExpanded(String nodeKey, {bool byDefault = true}) =>
      _expansion[nodeKey] ?? byDefault;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onConnectionChanged() {
    final connected = isConnected;
    if (connected && !_wasConnected) {
      // (Re)connected, e.g. after a hot restart: everything may have
      // changed. The connection also fires databasesChanged; loading twice
      // is harmless because only the latest load wins.
      unawaited(loadDatabases());
    }
    _wasConnected = connected;
    _notify();
  }

  /// Re-runs `database.list` and the schema overviews, keeping the
  /// selection when it still exists.
  Future<void> loadDatabases() async {
    if (!isConnected) return;
    final seq = ++_loadSeq;
    _loadingDatabases = true;
    _databasesError = null;
    _notify();
    try {
      final descriptors = await client.listDatabases();
      if (seq != _loadSeq) return;
      final nodes = [for (final d in descriptors) DatabaseNode(d)];
      _databases = nodes;
      _generation++;
      if (_selectedDatabaseId == null && nodes.isNotEmpty) {
        _selectedDatabaseId = nodes.first.id;
      }
      _validateSelection(keepEntity: true);
      _notify();
      await Future.wait([for (final n in nodes) _loadOverview(n, seq)]);
      if (seq != _loadSeq) return;
      _validateSelection(keepEntity: false);
      _rebuildTableController(reloadExisting: true);
    } on InspectorClientException catch (e) {
      if (seq != _loadSeq) return;
      _databasesError = Wording.error(e);
    } finally {
      if (seq == _loadSeq) {
        _loadingDatabases = false;
        _notify();
      }
    }
  }

  Future<void> _loadOverview(DatabaseNode node, int seq) async {
    node
      ..loading = true
      ..error = null;
    try {
      final overview = await client.schema(node.id);
      if (seq != _loadSeq) return;
      node.overview = overview;
    } on InspectorClientException catch (e) {
      node.error = Wording.error(e);
    } finally {
      node.loading = false;
      _notify();
    }
  }

  /// Reloads one database's tree (e.g. after inserts changed row counts).
  Future<void> refreshDatabase(String databaseId) async {
    final node = _databases.where((d) => d.id == databaseId).firstOrNull;
    if (node == null) return;
    await _loadOverview(node, _loadSeq);
  }

  void _validateSelection({required bool keepEntity}) {
    final db = selectedDatabase;
    if (db == null) {
      _selectedDatabaseId = _databases.firstOrNull?.id;
      _selectedEntity = null;
      return;
    }
    if (!keepEntity &&
        _selectedEntity != null &&
        db.overview != null &&
        db.entity(_selectedEntity!) == null) {
      _selectedEntity = null;
    }
    if (_tab == InspectorTab.sql &&
        !db.descriptor.capabilities.contains(DbCapability.sql)) {
      _tab = InspectorTab.data;
    }
  }

  /// Creates, keeps or reloads the [TableController] for the selection.
  void _rebuildTableController({bool reloadExisting = false}) {
    final db = selectedDatabase;
    final entity = selectedEntity;
    final current = _table;
    if (db == null || entity == null) {
      if (current != null) {
        _table = null;
        current.dispose();
      }
      return;
    }
    if (current != null &&
        current.databaseId == db.id &&
        current.table == entity.name) {
      current.rebind(db.descriptor, entity);
      if (reloadExisting) unawaited(current.reload(withSchema: true));
      return;
    }
    current?.dispose();
    final next = TableController(
      client: client,
      database: db.descriptor,
      entity: entity,
      limits: limits,
    );
    _table = next;
    unawaited(next.reload(withSchema: true));
  }

  void selectDatabase(String databaseId) {
    if (_selectedDatabaseId == databaseId && _selectedEntity == null) return;
    _selectedDatabaseId = databaseId;
    _selectedEntity = null;
    _validateSelection(keepEntity: false);
    if (_tab == InspectorTab.data) _tab = InspectorTab.schema;
    _rebuildTableController();
    _notify();
  }

  void selectEntity(String databaseId, String entity, {InspectorTab? tab}) {
    _selectedDatabaseId = databaseId;
    _selectedEntity = entity;
    _validateSelection(keepEntity: true);
    if (tab != null) {
      _tab = tab;
    } else if (_tab == InspectorTab.stats || _tab == InspectorTab.sql) {
      _tab = InspectorTab.data;
    }
    _rebuildTableController();
    _notify();
  }

  void setTab(InspectorTab tab) {
    if (_tab == tab) return;
    _tab = tab;
    _notify();
  }

  void setExpanded(String nodeKey, {required bool expanded}) {
    if (_expansion[nodeKey] == expanded) return;
    _expansion[nodeKey] = expanded;
    _notify();
  }

  /// The SQL console of [database], kept while the extension is open.
  SqlController sqlController(DatabaseDescriptor database) {
    final existing = _sql[database.id];
    if (existing != null) return existing..database = database;
    return _sql[database.id] = SqlController(
      client: client,
      database: database,
      history: history,
    );
  }

  /// Reloads everything (toolbar refresh).
  Future<void> refreshAll() => loadDatabases();

  @override
  void dispose() {
    _disposed = true;
    _connection.removeListener(_onConnectionChanged);
    unawaited(_databasesSubscription.cancel());
    _table?.dispose();
    for (final c in _sql.values) {
      c.dispose();
    }
    super.dispose();
  }
}
