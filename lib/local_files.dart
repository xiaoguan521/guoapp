import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_snapshot.dart';

class LocalFiles {
  LocalFiles(this.root);

  final Directory root;

  File _file(String name) => File(path.join(root.path, name));

  Future<bool> hasUsersFile() => _file('users.json').exists();

  Future<Object?> read(String name) async {
    final file = _file(name);
    final backup = File('${file.path}.bak');
    var found = false;
    for (final candidate in [file, backup]) {
      if (!await candidate.exists()) continue;
      found = true;
      try {
        return jsonDecode(await candidate.readAsString());
      } catch (_) {}
    }
    if (found) throw FormatException('$name 无法读取');
    return null;
  }

  Future<void> quarantine(String name) async {
    final file = _file(name);
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!await candidate.exists()) continue;
      var target = File('${candidate.path}.corrupt');
      var suffix = 2;
      while (await target.exists()) {
        target = File('${candidate.path}.corrupt-$suffix');
        suffix++;
      }
      await candidate.rename(target.path);
    }
  }

  Future<void> write(String name, Object? value) async {
    final file = _file(name);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    final backup = File('${file.path}.bak');
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }

  Future<void> remove(String name) async {
    for (final file in [_file(name), _file('$name.bak')]) {
      if (await file.exists()) await file.delete();
    }
  }
}

class LocalFilesState {
  LocalFilesState._(this.files, Map<String, Object> values)
    : _values = Map.of(values);

  static const _settingsFile = 'settings.json';
  static const _userMeta = {'profiles', 'activeProfile', 'forceLogin'};

  final LocalFiles files;
  Map<String, Object> _values;

  Map<String, Object> get values => Map.of(_values);

  static Future<LocalFilesState> open(SharedPreferences preferences) async {
    final support = await getApplicationSupportDirectory();
    final files = LocalFiles(Directory(path.join(support.path, 'local_store')));
    if (!await files.hasUsersFile()) {
      final snapshot = LocalSnapshot(preferences);
      final state = LocalFilesState._(files, {});
      if (snapshot.values.isNotEmpty) await state.commit(snapshot.values);
      return state;
    }
    try {
      final values = await _read(files);
      return LocalFilesState._(files, values);
    } on FormatException {
      Map<String, Object> values;
      try {
        values = LocalSnapshot(preferences).values;
      } catch (_) {
        values = {};
      }
      values.putIfAbsent('profiles', () => 'null');
      return LocalFilesState._(files, values);
    }
  }

  static Future<Map<String, Object>> _read(LocalFiles files) async {
    final values = <String, Object>{};
    final users = await files.read('users.json');
    if (users is! Map) throw const FormatException('用户配置无效');
    final userMap = Map<String, Object?>.from(users);
    if (userMap['profiles'] is! List ||
        (userMap.containsKey('activeProfile') &&
            userMap['activeProfile'] is! String) ||
        (userMap.containsKey('forceLogin') && userMap['forceLogin'] is! bool)) {
      throw const FormatException('用户配置无效');
    }
    for (final key in _userMeta) {
      final value = userMap[key];
      if (key == 'profiles' && value is List) {
        values[key] = jsonEncode(value);
      } else if (value is String || value is bool) {
        values[key] = value;
      }
    }
    final settings = await _readOptional(files, _settingsFile);
    if (settings != null && settings is! Map) {
      await files.quarantine(_settingsFile).catchError((Object _) {});
    } else if (settings is Map) {
      final parsed = <String, Object>{};
      var valid = true;
      for (final entry in settings.entries) {
        final key = entry.key;
        if (key is! String || !_validSettingsValue(key, entry.value)) {
          valid = false;
          break;
        }
        parsed[key] = entry.value as Object;
      }
      if (valid) {
        values.addAll(parsed);
      } else {
        await files.quarantine(_settingsFile).catchError((Object _) {});
      }
    }
    final profiles = _profileIds(values['profiles']);
    for (final id in profiles) {
      for (final key in LocalSnapshot.libraryKeys) {
        final name = _profileFile(id, key);
        final value = await _readOptional(files, name);
        final snapshotKey = _snapshotKey(id, key);
        if (value != null) {
          if (_validValue(snapshotKey, value)) {
            values[snapshotKey] = value;
          } else {
            await files.quarantine(name).catchError((Object _) {});
          }
        }
      }
    }
    return values;
  }

  static bool _validValue(String key, Object? value) {
    if (!LocalSnapshot.owns(key)) return false;
    final boolean = {
      'hideVip',
      'autoExport',
      'exportPosters',
      'forceLogin',
      'greenMode',
      'fullMode',
      'storagePromptShown',
      'liveActivated',
    }.contains(key.split('.').last);
    return boolean ? value is bool : value is String;
  }

  static bool _validSettingsValue(String key, Object? value) =>
      !_userMeta.contains(key) &&
      LocalSnapshot.globalKeys.contains(key) &&
      _validValue(key, value);

  static Future<Object?> _readOptional(LocalFiles files, String name) async {
    try {
      return await files.read(name);
    } on FormatException {
      await files.quarantine(name).catchError((Object _) {});
      return null;
    }
  }

  static Set<String> _profileIds(Object? raw) {
    if (raw is! String) return {'default'};
    try {
      final records = jsonDecode(raw);
      if (records is! List) return {'default'};
      final ids = <String>{'default'};
      for (final row in records) {
        final id = row is Map ? row['id'] : null;
        if (id is String && RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id)) {
          ids.add(id);
        }
      }
      return ids;
    } catch (_) {
      return {'default'};
    }
  }

  static String _snapshotKey(String id, String key) =>
      id == 'default' ? key : 'profile.$id.$key';

  static String _profileFile(String id, String key) =>
      path.join('users', id, '$key.json');

  static String? _profileFileForKey(String key) {
    if (LocalSnapshot.libraryKeys.contains(key)) {
      return _profileFile('default', key);
    }
    final match = RegExp(
      r'^profile\.([a-zA-Z0-9_-]{1,64})\.(.+)$',
    ).firstMatch(key);
    if (match == null || !LocalSnapshot.libraryKeys.contains(match[2])) {
      return null;
    }
    return _profileFile(match[1]!, match[2]!);
  }

  Future<void> commit(Map<String, Object> next) async {
    final previous = _values;
    final ids = {
      ..._profileIds(previous['profiles']),
      ..._profileIds(next['profiles']),
    };
    if (_userMeta.any(
      (key) => jsonEncode(previous[key]) != jsonEncode(next[key]),
    )) {
      await files.write('users.json', {
        for (final key in _userMeta)
          if (next[key] != null)
            key: key == 'profiles'
                ? jsonDecode(next[key] as String)
                : next[key],
      });
    }
    final globalKeys = {
      ...previous.keys.where(
        (key) => !_userMeta.contains(key) && _profileFileForKey(key) == null,
      ),
      ...next.keys.where(
        (key) => !_userMeta.contains(key) && _profileFileForKey(key) == null,
      ),
    };
    if (globalKeys.any(
      (key) => jsonEncode(previous[key]) != jsonEncode(next[key]),
    )) {
      await files.write(_settingsFile, {
        for (final key in globalKeys)
          if (next[key] != null) key: next[key],
      });
    }
    for (final id in ids) {
      for (final key in LocalSnapshot.libraryKeys) {
        final snapshotKey = _snapshotKey(id, key);
        if (jsonEncode(previous[snapshotKey]) ==
            jsonEncode(next[snapshotKey])) {
          continue;
        }
        final name = _profileFile(id, key);
        if (next[snapshotKey] == null) {
          await files.remove(name);
        } else {
          await files.write(name, next[snapshotKey]);
        }
      }
    }
    _values = Map.of(next);
  }

  Future<void> reload() async {
    if (!await files.hasUsersFile()) return;
    try {
      _values = await _read(files);
    } on FormatException {
      return;
    }
  }
}
