/// flutter_secure_storage adapter for Flutter DB Inspector.
///
/// ```dart
/// DbInspector.registerDatabase(
///   name: 'secrets',
///   adapter: SecureStorageAdapter(const FlutterSecureStorage()),
/// );
/// ```
library;

export 'src/secure_storage_adapter.dart';
export 'src/secure_storage_store.dart';
