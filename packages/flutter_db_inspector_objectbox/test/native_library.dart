import 'dart:ffi';
import 'dart:io';

/// ObjectBox C library version matching `objectbox` 5.3.x.
const _version = '5.3.2';

/// Makes the ObjectBox native library available to `dart test`.
///
/// Downloads the official objectbox-c release for the host into
/// `.dart_tool/objectbox` (what ObjectBox's `install.sh` does, but without
/// touching `lib/` or `/usr/local/lib`) and loads it into the process, where
/// `package:objectbox` finds it before searching the file system.
Future<void> loadObjectBoxLibrary() async {
  final (archive, file) = switch (Abi.current()) {
    Abi.macosArm64 || Abi.macosX64 => (
        'objectbox-macos-universal.zip',
        'libobjectbox.dylib',
      ),
    Abi.linuxX64 => ('objectbox-linux-x64.tar.gz', 'libobjectbox.so'),
    Abi.linuxArm64 => ('objectbox-linux-aarch64.tar.gz', 'libobjectbox.so'),
    final abi => throw UnsupportedError('No ObjectBox test library for $abi'),
  };
  final dir = Directory(
      '${Directory.current.path}/.dart_tool/objectbox/$_version/${Abi.current()}');
  final library = File('${dir.path}/lib/$file');
  if (!library.existsSync()) {
    dir.createSync(recursive: true);
    final download = File('${dir.path}/$archive');
    final uri = Uri.parse('https://github.com/objectbox/objectbox-c/releases/'
        'download/v$_version/$archive');
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(uri)).close();
      if (response.statusCode != 200) {
        throw StateError('Downloading $uri failed: ${response.statusCode}');
      }
      await response.pipe(download.openWrite());
    } finally {
      client.close();
    }
    final result = archive.endsWith('.zip')
        ? await Process.run(
            'unzip', ['-o', '-q', download.path, '-d', dir.path])
        : await Process.run('tar', ['-xzf', download.path, '-C', dir.path]);
    if (result.exitCode != 0) {
      throw StateError('Extracting $archive failed: ${result.stderr}');
    }
  }
  // macOS loads libraries with global symbol visibility, so ObjectBox's
  // DynamicLibrary.process() lookup finds this one.
  DynamicLibrary.open(library.path);
}
