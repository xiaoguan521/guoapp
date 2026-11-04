import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';

import 'app_build.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'media_library.dart';
import 'app_layout.dart';

const _updateChannel = MethodChannel('duanju/update');

class _Version implements Comparable<_Version> {
  _Version(this.name, this.build, this.parts);
  final String name;
  final int build;
  final List<int> parts;

  static _Version? parse(String value, {int build = 0}) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$',
    ).firstMatch(value);
    if (match == null) return null;
    return _Version(
      value.split('+').first,
      int.tryParse(match[4] ?? '') ?? build,
      [for (var i = 1; i <= 3; i++) int.parse(match[i]!)],
    );
  }

  @override
  int compareTo(_Version other) {
    for (var i = 0; i < parts.length; i++) {
      final compared = parts[i].compareTo(other.parts[i]);
      if (compared != 0) return compared;
    }
    return build.compareTo(other.build);
  }
}

class _Update {
  _Update(
    this.version,
    this.name,
    this.url,
    this.digest,
    this.size,
    this.notes,
    this.abi,
  );
  final _Version version;
  final String name, url, digest, notes, abi;
  final int size;
}

class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({
    super.key,
    required this.store,
    required this.repository,
  });
  final LocalStore store;
  final AppRepository repository;

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  HttpClient? _client;
  _Update? _update;
  File? _package;
  var _busy = false;
  var _cancelled = false;
  var _checking = false;
  var _installing = false;
  var _received = 0;
  var _permissionRequired = false;
  var _status = '';
  var _current = appVersion;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void dispose() {
    _cancelled = true;
    _client?.close(force: true);
    super.dispose();
  }

  bool _trusted(Uri uri, {bool metadata = false}) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.port != 443)
      return false;
    final allowed = updateAllowedHosts
        .split(',')
        .map((h) => h.trim())
        .where((h) => h.isNotEmpty)
        .toSet();
    final metadataHost = Uri.tryParse(updateMetadataUrl)?.host ?? '';
    if (metadata) return uri.host == metadataHost && allowed.contains(uri.host);
    if (!allowed.contains(uri.host)) return false;
    if (updateDownloadPathPrefix.isNotEmpty) {
      if (uri.path.startsWith(updateDownloadPathPrefix)) return true;
      if (uri.host == metadataHost) return false;
    }
    return true;
  }

  Future<HttpClientResponse> _get(Uri uri, {bool metadata = false}) async {
    for (var redirects = 0; redirects <= 4; redirects++) {
      if (!_trusted(uri, metadata: metadata)) throw const FormatException();
      final request = await _client!
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, '$appSlug-update');
      request.headers.set(
        HttpHeaders.acceptHeader,
        metadata ? 'application/vnd.github+json' : 'application/octet-stream',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(const Duration(seconds: 10));
        if (location == null) throw const FormatException();
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok)
        throw const HttpException('release unavailable');
      return response;
    }
    throw const FormatException();
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _checking = true;
      _cancelled = false;
      _update = null;
      _package = null;
      _permissionRequired = false;
      _status = '正在查询官方发布记录…';
    });
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final info = Platform.isAndroid
          ? await _updateChannel.invokeMapMethod<String, dynamic>('info')
          : await AppDevice.channel.invokeMapMethod<String, dynamic>(
              'deviceInfo',
            );
      final current = _Version.parse(
        info?['version'] as String? ?? '',
        build: (info?['build'] as num?)?.toInt() ?? 0,
      );
      if (current == null) throw const FormatException();
      _current = '${current.name}+${current.build}';
      final abis = Platform.isAndroid
          ? (info?['abis'] as List? ?? const []).whereType<String>().toList()
          : <String>[if (Platform.isWindows) 'windows-x64'];
      final response = await _get(Uri.parse(updateMetadataUrl), metadata: true);
      final body = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 25))) {
        body.addAll(chunk);
        if (body.length > 4 * 1024 * 1024) throw const FormatException();
      }
      final releases = jsonDecode(utf8.decode(body)) as List;
      _Update? newest;
      for (final raw in releases) {
        final release = raw as Map<String, dynamic>;
        if (release['draft'] != false || release['prerelease'] != false)
          continue;
        final tag = release['tag_name'] as String? ?? '';
        final prefix = android6Compatibility ? 'android6-' : 'v';
        if (!tag.startsWith(prefix)) continue;
        final tagVersion = _Version.parse(tag.substring(prefix.length));
        if (tagVersion == null) continue;
        for (final rawAsset in release['assets'] as List? ?? const []) {
          final asset = rawAsset as Map<String, dynamic>;
          final name = asset['name'] as String? ?? '';
          final extension = Platform.isAndroid ? 'apk' : 'zip';
          final assetSlug = android6Compatibility
              ? '$appSlug-android6'
              : appSlug;
          final match = RegExp(
            '^${RegExp.escape(assetSlug)}-(\\d+\\.\\d+\\.\\d+\\+\\d+)-(.+)\\.$extension\$',
          ).firstMatch(name);
          if (match == null || !abis.contains(match[2])) continue;
          final version = _Version.parse(match[1]!);
          if (version == null ||
              version.name != tagVersion.name ||
              version.compareTo(current) <= 0)
            continue;
          final address = asset['browser_download_url'] as String? ?? '';
          final uri = Uri.tryParse(address);
          final digest = asset['digest'] as String? ?? '';
          final size = (asset['size'] as num?)?.toInt() ?? 0;
          if (uri == null ||
              !_trusted(uri) ||
              !digest.startsWith('sha256:') ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest.substring(7)) ||
              size <= 0 ||
              size > 1024 * 1024 * 1024)
            continue;
          final notes = release['body'] as String? ?? '';
          final candidate = _Update(
            version,
            name,
            address,
            digest.substring(7),
            size,
            notes.length > 12000 ? notes.substring(0, 12000) : notes,
            match[2]!,
          );
          if (newest == null ||
              candidate.version.compareTo(newest.version) > 0 ||
              (candidate.version.compareTo(newest.version) == 0 &&
                  abis.indexOf(match[2]!) < abis.indexOf(newest.abi)))
            newest = candidate;
        }
      }
      if (!mounted || _cancelled) return;
      setState(() {
        _update = newest;
        _status = newest == null
            ? (Platform.isAndroid
                  ? '未发现适合当前版本的新安装包。也可打开发布页查看打包进度。'
                  : '当前平台请前往官方发布页检查并安装更新。')
            : '发现新版本 ${newest.version.name}+${newest.version.build}';
      });
    } catch (_) {
      if (mounted && !_cancelled)
        setState(() => _status = '检查失败，请检查网络后重试，或打开官方发布页。');
    } finally {
      _client?.close(force: true);
      if (mounted)
        setState(() {
          _busy = false;
          _checking = false;
        });
    }
  }

  Future<void> _download() async {
    final update = _update;
    if (_busy || update == null) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _received = 0;
      _status = '正在下载安装包…';
    });
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    File? partial;
    try {
      final root = await getTemporaryDirectory();
      final directory = Directory(
        paths.join(root.path, 'app_updates', appSlug),
      );
      await directory.create(recursive: true);
      final target = File(paths.join(directory.path, update.name));
      partial = File('${target.path}.part');
      final response = await _get(Uri.parse(update.url));
      if (response.contentLength > 0 && response.contentLength != update.size)
        throw const FormatException();
      final sink = partial.openWrite();
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (_cancelled) throw const HttpException('cancelled');
          _received += chunk.length;
          if (_received > update.size) throw const FormatException();
          sink.add(chunk);
          await sink.flush();
          if (mounted) setState(() {});
        }
      } finally {
        await sink.close();
      }
      if (_cancelled || _received != update.size) throw const FormatException();
      if (mounted) setState(() => _status = '正在校验安装包…');
      final digest = await sha256.bind(partial.openRead()).first;
      if (_cancelled || digest.toString() != update.digest)
        throw const FormatException();
      if (await target.exists()) await target.delete();
      _package = await partial.rename(target.path);
      if (mounted)
        setState(() => _status = '下载和完整性校验完成。点击安装会暂停下载与合并任务，系统仍会要求确认。');
    } catch (_) {
      if (mounted)
        setState(() => _status = _cancelled ? '下载已取消。' : '下载或完整性校验失败，请重新下载。');
    } finally {
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } on FileSystemException {
        if (mounted && !_cancelled)
          setState(() => _status = '无法清理临时下载文件，请检查可用空间后重试。');
      }
      _client?.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    if (_busy || _package == null || _update == null) return;
    setState(() {
      _busy = true;
      _installing = true;
      _status = '正在核对安装包、签名和版本…';
    });
    try {
      final allowed =
          await _updateChannel.invokeMethod<bool>('canInstall') ?? false;
      if (allowed) {
        final library = MediaLibrary.current;
        if (library?.busy == true) {
          if (mounted) setState(() => _status = '请等待本地媒体处理结束后再安装更新。');
          return;
        }
        await library?.merges.pauseUnavailable(all: true);
        if (widget.store.canDownload)
          await widget.repository.controlDownloads('pauseAll');
        await widget.store.flushPendingWrites();
      }
      final outcome = await _updateChannel.invokeMethod<String>('install', {
        'path': _package!.path,
        'sha256': _update!.digest,
      });
      if (!mounted) return;
      setState(() {
        _permissionRequired = outcome == 'permissionRequired';
        _status = _permissionRequired
            ? '安装更新需要允许本应用作为安装来源。仅在你主动安装更新时使用，不需要存储权限。授权后返回并点击继续安装。'
            : '已打开系统安装器，请按系统提示确认。打开安装器不代表更新已完成。';
      });
    } on PlatformException catch (error) {
      if (mounted)
        setState(() => _status = error.message ?? '无法打开安装器，请从发布页下载安装。');
    } catch (_) {
      if (mounted) setState(() => _status = '无法打开安装器，请从发布页下载安装。');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _installing = false;
        });
    }
  }

  Future<void> _openPage() async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [updateReleasePage]);
      } else {
        await _updateChannel.invokeMethod<void>('openReleasePage', {
          'url': updateReleasePage,
          'host': Uri.tryParse(updateReleasePage)?.host ?? '',
        });
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: updateReleasePage));
      if (mounted) setState(() => _status = '官方下载页地址已复制，请在浏览器中打开。');
    }
  }

  Future<void> _permission() async {
    try {
      await _updateChannel.invokeMethod<void>('openInstallSettings');
    } catch (_) {
      if (mounted) setState(() => _status = '无法打开安装来源设置，请在系统设置中检查。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = _update;
    return PopScope(
      canPop: !_installing,
      child: Scaffold(
        appBar: AppBar(title: const Text('检查更新')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('$appName · 当前版本 $_current'),
            const SizedBox(height: 16),
            Text(_status),
            if (_busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: !_checking && update != null && _received > 0
                    ? _received / update.size
                    : null,
              ),
            ],
            if (update != null) ...[
              const SizedBox(height: 12),
              Text('${(update.size / 1024 / 1024).toStringAsFixed(1)} MB'),
              const SizedBox(height: 12),
              SelectableText(
                update.notes.isEmpty ? '此版本未提供更新说明。' : update.notes,
              ),
              const SizedBox(height: 16),
              if (!Platform.isAndroid)
                FilledButton(
                  onPressed: _busy ? null : _openPage,
                  child: const Text('前往发布页下载更新'),
                )
              else if (_package == null)
                FilledButton(
                  onPressed: _busy ? null : _download,
                  child: const Text('下载更新'),
                )
              else ...[
                if (_permissionRequired)
                  OutlinedButton(
                    onPressed: _busy ? null : _permission,
                    child: const Text('打开安装授权设置'),
                  ),
                FilledButton(
                  onPressed: _busy ? null : _install,
                  child: Text(_permissionRequired ? '继续安装' : '安装更新'),
                ),
              ],
            ],
            const SizedBox(height: 12),
            if (_busy && !_checking && !_installing)
              TextButton(
                onPressed: () {
                  _cancelled = true;
                  _client?.close(force: true);
                },
                child: const Text('取消下载'),
              ),
            OutlinedButton(
              onPressed: _busy ? null : _check,
              child: const Text('重新检查'),
            ),
            TextButton(
              onPressed: _busy ? null : _openPage,
              child: const Text('打开官方发布页'),
            ),
            const SizedBox(height: 12),
            const Text(
              '仅在你点击检查或下载时连接官方发布渠道。Android 安装前核对文件摘要、应用签名和版本，不自动安装。Windows 和 iOS 通过发布页手动安装。',
            ),
          ],
        ),
      ),
    );
  }
}
