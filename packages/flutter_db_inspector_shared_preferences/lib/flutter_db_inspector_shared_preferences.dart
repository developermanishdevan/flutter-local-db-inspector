/// SharedPreferences adapter for Flutter DB Inspector.
///
/// ```dart
/// final prefs = await SharedPreferences.getInstance();
/// DbInspector.registerDatabase(
///   name: 'prefs',
///   adapter: SharedPreferencesAdapter(prefs),
/// );
/// ```
library;

export 'src/shared_preferences_adapter.dart';
export 'src/shared_preferences_store.dart';
