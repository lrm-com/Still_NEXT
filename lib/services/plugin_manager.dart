import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

class PluginMetadata {
  const PluginMetadata({required this.id, required this.name, required this.version, this.type = 'generic', this.capabilities = const [], this.library});
  final String id, name, version, type;
  final List<String> capabilities;
  final String? library;
  factory PluginMetadata.fromJson(Map<String, dynamic> json) => PluginMetadata(id: json['id'] as String? ?? '', name: json['name'] as String? ?? json['id'] as String? ?? '', version: json['version'] as String? ?? '0.0.0', type: json['type'] as String? ?? 'generic', capabilities: [for (final value in (json['capabilities'] as List? ?? const [])) '$value',], library: json['library'] as String?);
}

class LoadedPlugin {
  LoadedPlugin(this.metadata, this.directory, {this.library});
  final PluginMetadata metadata;
  final Directory directory;
  final DynamicLibrary? library;
  bool enabled = true;
  bool get loaded => library != null;
  bool hasSymbol(String name) { if (library == null) return false; try { library!.lookup<NativeType>(name); return true; } on Object { return false; } }
}

class PluginManager {
  PluginManager({Directory? pluginsDirectory}) : pluginsDirectory = pluginsDirectory ?? Directory('plugins');
  final Directory pluginsDirectory;
  final _plugins = <String, LoadedPlugin>{};
  Map<String, LoadedPlugin> get plugins => Map.unmodifiable(_plugins);
  LoadedPlugin? getPlugin(String id) => _plugins[id];

  Future<List<LoadedPlugin>> scan() async {
    if (!await pluginsDirectory.exists()) return List.unmodifiable(_plugins.values);
    await for (final entity in pluginsDirectory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final metadataFile = File('${entity.path}${Platform.pathSeparator}plugin.json');
      if (!await metadataFile.exists()) continue;
      try {
        final metadata = PluginMetadata.fromJson(jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>);
        if (metadata.id.isEmpty) continue;
        _plugins[metadata.id] = LoadedPlugin(metadata, entity);
      } on Object { /* Ignore malformed third-party plugin metadata. */ }
    }
    return List.unmodifiable(_plugins.values);
  }
  Future<List<LoadedPlugin>> discover() => scan();
  Future<List<LoadedPlugin>> loadAll() async {
    final result = <LoadedPlugin>[];
    for (final plugin in await scan()) {
      try { result.add(await load(plugin.metadata.id)); } on Object { /* Keep other plugins usable when one library is unavailable. */ }
    }
    return List.unmodifiable(result);
  }

  Future<LoadedPlugin> load(String id) async {
    final plugin = _plugins[id] ?? (await scan()).firstWhere((p) => p.metadata.id == id, orElse: () => throw StateError('Plugin not found: $id'));
    if (plugin.library != null) return plugin;
    final path = plugin.metadata.library == null ? _findLibrary(plugin.directory, id) : '${plugin.directory.path}${Platform.pathSeparator}${plugin.metadata.library}';
    if (path == null) throw StateError('No dynamic library found for plugin $id');
    final library = DynamicLibrary.open(path);
    final loaded = LoadedPlugin(plugin.metadata, plugin.directory, library: library)..enabled = plugin.enabled;
    _plugins[id] = loaded;
    _callOptionalInit(loaded);
    return loaded;
  }

  void setEnabled(String id, bool enabled) { final plugin = _plugins[id]; if (plugin != null) plugin.enabled = enabled; }
  Future<void> unload(String id) async { final plugin = _plugins.remove(id); if (plugin != null && plugin.library != null) _callOptionalDispose(plugin); }
  Future<void> unloadAll() async { for (final id in _plugins.keys.toList()) await unload(id); }

  static String? _findLibrary(Directory directory, String id) {
    final names = Platform.isWindows ? ['$id.dll', 'lib$id.dll'] : Platform.isMacOS ? ['lib$id.dylib', '$id.dylib'] : ['lib$id.so', '$id.so'];
    for (final name in names) { final path = '${directory.path}${Platform.pathSeparator}$name'; if (File(path).existsSync()) return path; }
    return null;
  }
  static void _callOptionalInit(LoadedPlugin plugin) { try { final fn = plugin.library!.lookupFunction<Void Function(), void Function()>('plugin_init'); fn(); } on Object {} }
  static void _callOptionalDispose(LoadedPlugin plugin) { try { final fn = plugin.library!.lookupFunction<Void Function(), void Function()>('plugin_dispose'); fn(); } on Object {} }
}

class DsdDecoderPlugin {
  DsdDecoderPlugin(this.plugin, {this.decoder});
  final LoadedPlugin plugin;
  final Uint8List Function(String filePath)? decoder;
  bool get available => plugin.enabled && (decoder != null || (plugin.loaded && plugin.hasSymbol('dsd_decode')));
  Uint8List decode(String filePath) {
    if (!available) throw StateError('DSD decoder plugin is not available');
    final callback = decoder;
    if (callback == null) throw UnsupportedError('DSD decode ABI must be supplied by the loaded plugin');
    return callback(filePath);
  }
}

class OnlineLyricsPlugin {
  OnlineLyricsPlugin(this.plugin, {this.searcher, this.fetcher, this.sourcesProvider});
  final LoadedPlugin plugin;
  final Future<List<Map<String, String>>> Function({required String artist, required String title})? searcher;
  final Future<String> Function(String id)? fetcher;
  final Future<List<String>> Function()? sourcesProvider;
  bool get available => plugin.enabled && (searcher != null || (plugin.loaded && plugin.hasSymbol('lyrics_search')));
  Future<List<Map<String, String>>> search({required String artist, required String title}) async {
    if (!available || searcher == null) throw StateError('Online lyrics plugin is not available');
    return List.unmodifiable(await searcher!(artist: artist, title: title));
  }
  Future<String> fetch(String id) async {
    if (!available || fetcher == null) throw StateError('Online lyrics plugin is not available');
    return fetcher!(id);
  }
  Future<List<String>> sources() async {
    if (!available || sourcesProvider == null) return const [];
    return List.unmodifiable(await sourcesProvider!());
  }
}
