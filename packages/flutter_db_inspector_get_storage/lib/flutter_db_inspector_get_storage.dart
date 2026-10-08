/// GetStorage adapter for Flutter DB Inspector.
///
/// ```dart
/// await GetStorage.init();
/// DbInspector.registerDatabase(
///   name: 'storage',
///   adapter: GetStorageAdapter({'GetStorage': GetStorage()}),
/// );
/// ```
library;

export 'src/get_storage_adapter.dart';
export 'src/get_storage_store.dart';
