import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector/flutter_db_inspector.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'seed.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Open the app's real storage...
  final db = await openDatabase(
    p.join(await getDatabasesPath(), 'app_database.db'),
    version: 1,
    onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    onCreate: createAndSeed,
  );
  Hive.init((await getApplicationSupportDirectory()).path);
  final cache = await Hive.openBox<Object?>('cache');
  if (cache.isEmpty) {
    await cache.putAll({
      'last_sync': DateTime.now().toIso8601String(),
      'feature_flags': {'newCheckout': true, 'darkMode': false},
      'recent_searches': ['shoes', 'watch', 'headphones'],
      42: 'integer key',
    });
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('launch_count', (prefs.getInt('launch_count') ?? 0) + 1);
  await prefs.setString('locale', prefs.getString('locale') ?? 'en_IN');

  // 2. ...and hand it to the inspector (debug builds only). Each engine keeps
  //    its own data model: SQLite tables, Hive boxes, preference entries.
  DbInspector.initialize(
    enabled: kDebugMode,
    sensitiveColumns: {'users.password', 'users.phone'},
    databases: [
      InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
      InspectorDatabase(name: 'cache', adapter: HiveAdapter([cache])),
      InspectorDatabase(
        name: 'preferences',
        adapter: SharedPreferencesAdapter(prefs),
      ),
    ],
  );

  runApp(ExampleApp(db: db, cache: cache, prefs: prefs));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({
    super.key,
    required this.db,
    required this.cache,
    required this.prefs,
  });

  final Database db;
  final Box<Object?> cache;
  final SharedPreferences prefs;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Flutter DB Inspector example',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
        ),
        home: Dashboard(db: db, cache: cache, prefs: prefs),
      );
}

/// Shows live counts so edits made from the inspector are visible here.
class Dashboard extends StatefulWidget {
  const Dashboard({
    super.key,
    required this.db,
    required this.cache,
    required this.prefs,
  });

  final Database db;
  final Box<Object?> cache;
  final SharedPreferences prefs;

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final _random = Random();
  Map<String, int> _counts = const {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final counts = <String, int>{};
    for (final table in ['users', 'products', 'orders', 'order_items']) {
      counts[table] = Sqflite.firstIntValue(
            await widget.db.rawQuery('SELECT COUNT(*) FROM $table'),
          ) ??
          0;
    }
    if (mounted) setState(() => _counts = counts);
  }

  Future<void> _addUser() async {
    final n = _random.nextInt(1 << 20);
    await widget.db.insert('users', {
      'name': 'New user $n',
      'email': 'new$n@example.com',
      'is_active': 1,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter DB Inspector example'),
        actions: [
          IconButton(
            tooltip: 'Refresh counts',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            DbInspector.isEnabled
                ? 'Inspector enabled (${DbInspector.mode.name}). Open the '
                    'Flutter DB view in VS Code, DevTools or Android Studio.'
                : 'Inspector disabled (release build).',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          Text('app_database (SQLite)', style: theme.textTheme.titleMedium),
          for (final entry in _counts.entries)
            ListTile(
              dense: true,
              leading: const Icon(Icons.table_chart_outlined),
              title: Text(entry.key),
              trailing: Text('${entry.value}'),
            ),
          const Divider(),
          Text('cache (Hive)', style: theme.textTheme.titleMedium),
          ListTile(
            dense: true,
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('entries'),
            trailing: Text('${widget.cache.length}'),
          ),
          Text(
            'preferences (SharedPreferences)',
            style: theme.textTheme.titleMedium,
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.tune),
            title: const Text('launch_count'),
            trailing: Text('${widget.prefs.getInt('launch_count')}'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _addUser,
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Insert a user from the app'),
          ),
        ],
      ),
    );
  }
}
