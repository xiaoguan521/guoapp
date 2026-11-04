import 'player_route.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'app_notice.dart';
import 'core_bridge.dart';
import 'download_collections.dart';
import 'glass_panel.dart';
import 'local_store.dart';
import 'local_media_screen.dart';
import 'media_library.dart';
import 'models.dart';
import 'player_screen.dart';
import 'remote_widgets.dart';
import 'settings_screen.dart';
import 'storage_access.dart';
import 'widgets.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.playerBuilder,
  });
  final AppRepository repository;
  final LocalStore store;
  final bool embedded;
  @visibleForTesting
  final Widget Function(DramaDetail, int, double)? playerBuilder;
  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _CollectionMenu {
  const _CollectionMenu(this.collection);
  final DownloadCollection collection;
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  Timer? _timer;
  int _idlePolls = 0;
  final _search = TextEditingController();
  final _selected = <String>{};
  final _expanded = <String>{};
  final _collectionMenuKeys = <String, GlobalKey>{};
  final _listKey = GlobalKey<RemoteListState>();
  final _toolbarKey = GlobalKey<RemoteRowState>();
  final _batchKey = GlobalKey<RemoteRowState>();
  late final DownloadCollectionUpdater _updater;
  late final int _epoch;
  List<DownloadJob> _jobs = [];
  bool _loading = true,
      _refreshing = false,
      _opening = false,
      _selecting = false,
      _busy = false,
      _stopBatch = false;
  String? _error, _retryCommand;
  String _filter = 'all', _release = '', _operation = '';
  bool get _allowed =>
      widget.store.profileEpoch == _epoch && widget.store.canDownload;
  List<DownloadCollection> get _collections => downloadCollections(
    _jobs,
    query: _search.text,
    filter: _filter,
    release: _release,
  );

  @override
  void initState() {
    super.initState();
    _epoch = widget.store.profileEpoch;
    _updater = DownloadCollectionUpdater(widget.repository, widget.store)
      ..addListener(_changed);
    widget.store.addListener(_changed);
    widget.store.libraryChanges.addListener(_changed);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stopBatch = true;
    _timer?.cancel();
    _search.dispose();
    widget.store.removeListener(_changed);
    widget.store.libraryChanges.removeListener(_changed);
    _updater.removeListener(_changed);
    _updater.dispose();
    super.dispose();
  }

  void _poll() {
    if (_jobs.any((job) => job.active || job.state == 'removing')) {
      _idlePolls = 0;
    } else {
      _idlePolls++;
      if (_idlePolls % 5 != 1) return;
    }
    _refresh();
  }

  bool _sameJobs(List<DownloadJob> jobs) {
    if (jobs.length != _jobs.length) return false;
    for (var index = 0; index < jobs.length; index++) {
      final next = jobs[index];
      final previous = _jobs[index];
      if (next.id != previous.id ||
          next.state != previous.state ||
          next.progress != previous.progress ||
          next.bytes != previous.bytes ||
          next.total != previous.total ||
          next.actualQuality != previous.actualQuality ||
          next.error != previous.error ||
          next.archived != previous.archived ||
          next.revision != previous.revision) {
        return false;
      }
    }
    return true;
  }

  Future<void> _refresh() async {
    if (_refreshing || !_allowed) return;
    _refreshing = true;
    try {
      final jobs = await widget.repository.downloads();
      if (mounted && _allowed && (_error != null || !_sameJobs(jobs))) {
        setState(() {
          _jobs = jobs;
          _selected.retainAll(jobs.map((job) => job.id));
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && _allowed) setState(() => _error = error.toString());
    } finally {
      _refreshing = false;
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  void _message(String message) {
    if (mounted) {
      AppNotice.show(context, message);
    }
  }

  Future<void> _batch(String command, Iterable<DownloadJob> source) async {
    if (_busy || !_allowed) return;
    final jobs = source
        .where(
          (job) => switch (command) {
            'pause' => job.active,
            'resume' => job.resumable,
            'archive' => job.completed && !job.archived,
            'restore' => job.completed && job.archived,
            'remove' => true,
            _ => false,
          },
        )
        .toList();
    if (jobs.isEmpty) {
      _message('没有适合此操作的任务');
      return;
    }
    if (command == 'remove') {
      final completed = jobs.where((job) => job.completed).length;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(completed > 0 ? '删除所选视频？' : '取消所选下载？'),
          content: Text(
            '共 ${jobs.length} 项${completed > 0 ? '，包含 $completed 个已下载视频' : ''}，文件也会删除。\n需要保留视频时，请选择“清理任务，保留视频”。',
          ),
          actions: [
            TextButton(
              autofocus: AppLayout.isTelevision(context),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted || !_allowed) return;
    }
    setState(() {
      _busy = true;
      _stopBatch = false;
      _retryCommand = null;
    });
    final failures = <String, String>{};
    var completed = 0;
    try {
      for (var offset = 0; offset < jobs.length; offset += 500) {
        if (!mounted || !_allowed || _stopBatch) break;
        setState(
          () => _operation =
              '正在处理 ${math.min(offset + 500, jobs.length)}/${jobs.length} 项',
        );
        final ids = jobs
            .sublist(offset, math.min(offset + 500, jobs.length))
            .map((job) => job.id)
            .toList();
        try {
          final result = await widget.repository.controlDownloadBatch(
            command,
            ids,
          );
          if (!mounted || !_allowed) return;
          completed += result.completed.length;
          _selected.removeAll(result.completed);
          failures.addAll(result.failures);
        } catch (error) {
          failures.addAll({for (final id in ids) id: error.toString()});
        }
      }
      if (!mounted || !_allowed) return;
      if (failures.isNotEmpty) {
        _selected.addAll(failures.keys);
        _selecting = true;
        _retryCommand = command;
        _message(
          '已处理 $completed 项，${failures.length} 项失败：${failures.values.first}',
        );
      } else {
        _message(
          _stopBatch
              ? '已停止，已处理 $completed 项'
              : command == 'archive'
              ? '已清理 $completed 项任务，视频仍可本地播放'
              : '已处理 $completed 项',
        );
      }
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _operation = '';
        });
      }
    }
  }

  Future<void> _update(Drama drama) async {
    await _updater.update(drama);
    if (mounted && _allowed) {
      _message(_updater.error ?? _updater.status);
      await _refresh();
    }
  }

  Future<void> _play(DownloadJob job) async {
    if (_opening || !_allowed) return;
    _opening = true;
    final completed =
        _jobs
            .where((entry) => entry.completed && entry.drama.id == job.drama.id)
            .toList()
          ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    final index = completed.indexWhere((entry) => entry.id == job.id);
    if (index < 0) {
      _opening = false;
      return;
    }
    final detail = DramaDetail(
      job.drama,
      completed.map((entry) => entry.episode).toList(),
    );
    final watch = widget.store.watched(job.drama.id);
    final position = watch?.episode == job.episode.number && !watch!.finished
        ? watch.position
        : 0.0;
    try {
      await Navigator.of(context).push(
        playerRoute(
          widget.playerBuilder?.call(detail, index, position) ??
              PlayerScreen(
                detail: detail,
                initialIndex: index,
                initialPosition: position,
                repository: widget.repository,
                store: widget.store,
                localOnly: true,
              ),
        ),
      );
    } finally {
      _opening = false;
      if (mounted) await _refresh();
    }
  }

  void _select(Iterable<DownloadJob> jobs) {
    final ids = jobs.map((job) => job.id).toSet();
    setState(() {
      _selecting = true;
      if (ids.every(_selected.contains)) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  Future<void> _filters() async {
    var state = _filter, release = _release;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('筛选下载合集'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('任务状态'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in const {
                        'all': '全部任务',
                        'pending': '未完成',
                        'active': '进行中',
                        'paused': '已暂停',
                        'failed': '失败',
                        'completed': '已下载',
                        'archived': '已保留视频',
                      }.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: state == entry.key,
                          onSelected: (_) => change(() => state = entry.key),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text('剧集状态'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in const {
                        '': '全部',
                        'ongoing': '连载中',
                        'finished': '已完结',
                      }.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: release == entry.key,
                          onSelected: (_) => change(() => release = entry.key),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      setState(() {
        _filter = state;
        _release = release;
      });
    }
  }

  List<Widget> _titleActions(List<DownloadCollection> collections) => [
    if (_selecting) ...[
      IconButton(
        tooltip: '全选当前',
        onPressed: _busy
            ? null
            : () => _select(collections.expand((c) => c.jobs)),
        icon: const Icon(Icons.select_all_rounded),
      ),
      IconButton(
        tooltip: '退出多选',
        onPressed: _busy
            ? null
            : () => setState(() {
                _selecting = false;
                _selected.clear();
                _retryCommand = null;
              }),
        icon: const Icon(Icons.close_rounded),
      ),
    ] else ...[
      IconButton(
        tooltip: '筛选下载合集',
        onPressed: _filters,
        icon: Badge(
          isLabelVisible: _filter != 'all' || _release.isNotEmpty,
          child: const Icon(Icons.filter_list_rounded),
        ),
      ),
      IconButton(
        tooltip: '多选下载任务',
        onPressed: () => setState(() => _selecting = true),
        icon: const Icon(Icons.checklist_rounded),
      ),
      IconButton(
        key: const ValueKey('download-local-media'),
        tooltip: '本地媒体与合并',
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => LocalMediaScreen(
              repository: widget.repository,
              store: widget.store,
            ),
          ),
        ),
        icon: const Icon(Icons.video_library_outlined),
      ),
    ],
    Builder(
      builder: (menuContext) => IconButton(
        key: const ValueKey('download-queue-actions'),
        tooltip: '队列操作',
        onPressed: !_busy
            ? () {
                final anchor = glassMenuAnchor(menuContext);
                if (anchor != null) unawaited(_openQueueMenu(anchor));
              }
            : null,
        icon: const Icon(Icons.more_vert_rounded),
      ),
    ),
  ];

  Future<void> _openQueueMenu(Rect anchor) async {
    final value = await showGlassMenu<String>(
      context: context,
      anchor: anchor,
      alignRight: true,
      width: 320,
      entries: const [
        GlassMenuEntry(
          value: 'pause',
          label: Text('全部暂停'),
          leading: Icon(Icons.pause_circle_outline),
        ),
        GlassMenuEntry(
          value: 'resume',
          label: Text('全部继续'),
          leading: Icon(Icons.play_circle_outline),
        ),
        GlassMenuEntry(
          value: 'archive',
          label: Text('清理已完成任务，保留视频'),
          leading: Icon(Icons.cleaning_services_outlined),
        ),
        GlassMenuEntry(
          value: 'refresh',
          label: Text('刷新记录'),
          leading: Icon(Icons.refresh_rounded),
        ),
      ],
    );
    if (!mounted || value == null) return;
    if (value == 'refresh') {
      unawaited(_refresh());
    } else {
      unawaited(_batch(value, _jobs));
    }
  }

  Widget _collection(DownloadCollection collection) {
    final count = collection.jobs
        .where((job) => _selected.contains(job.id))
        .length;
    final expanded = _expanded.contains(collection.drama.id);
    return Card(
      child: ListTile(
        leading: _selecting
            ? Checkbox(
                tristate: true,
                value: count == 0
                    ? false
                    : count == collection.jobs.length
                    ? true
                    : null,
                onChanged: _busy ? null : (_) => _select(collection.jobs),
              )
            : Icon(expanded ? Icons.folder_open_rounded : Icons.folder_rounded),
        title: Text(
          collection.drama.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${collection.completed}/${collection.jobs.length} 集已下载 · ${storageSize(collection.bytes)}'
          '${collection.active > 0 ? ' · ${collection.active} 项进行中' : ''}${collection.failed > 0 ? ' · ${collection.failed} 项失败' : ''}',
        ),
        onTap: () => setState(() {
          if (!_expanded.remove(collection.drama.id)) {
            _expanded.add(collection.drama.id);
          }
        }),
        trailing: IconButton(
          key: _collectionMenuKeys.putIfAbsent(
            collection.drama.id,
            GlobalKey.new,
          ),
          tooltip: '${collection.drama.title} · 合集操作',
          onPressed: !_busy ? () => _openCollectionMenu(collection) : null,
          icon: const Icon(Icons.more_vert_rounded),
        ),
      ),
    );
  }

  Future<void> _openCollectionMenu(DownloadCollection collection) async {
    final anchorContext =
        _collectionMenuKeys[collection.drama.id]?.currentContext;
    final object = anchorContext?.findRenderObject();
    if (anchorContext == null ||
        object is! RenderBox ||
        Overlay.of(anchorContext).context.findRenderObject() is! RenderBox) {
      return;
    }
    final overlay =
        Overlay.of(anchorContext).context.findRenderObject() as RenderBox;
    final anchor = MatrixUtils.transformRect(
      object.getTransformTo(overlay),
      Offset.zero & object.size,
    );
    final action = await showGlassMenu<String>(
      context: context,
      anchor: anchor,
      alignRight: true,
      width: 320,
      maxHeight: 460,
      entries: [
        GlassMenuEntry(
          value: 'update',
          label: const Text('更新本剧 · 补充新增与缺失'),
          leading: const Icon(Icons.update_rounded),
          enabled: !_updater.busy,
        ),
        const GlassMenuEntry(
          value: 'export',
          label: Text('导出到文件夹…'),
          leading: Icon(Icons.folder_copy_outlined),
        ),
        const GlassMenuEntry(
          value: 'select',
          label: Text('选择本合集'),
          leading: Icon(Icons.checklist_rounded),
        ),
        const GlassMenuEntry(
          value: 'pause',
          label: Text('暂停本合集'),
          leading: Icon(Icons.pause_circle_outline),
        ),
        const GlassMenuEntry(
          value: 'resume',
          label: Text('继续 / 重试本合集'),
          leading: Icon(Icons.play_circle_outline),
        ),
        const GlassMenuEntry(
          value: 'archive',
          label: Text('清理已完成任务，保留视频'),
          leading: Icon(Icons.cleaning_services_outlined),
        ),
        if (_filter == 'archived')
          const GlassMenuEntry(
            value: 'restore',
            label: Text('恢复到任务列表'),
            leading: Icon(Icons.restore),
          ),
        const GlassMenuEntry(
          value: 'remove',
          label: Text('取消任务并删除视频'),
          leading: Icon(Icons.delete_outline),
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'update') {
      _update(collection.drama);
    } else if (action == 'export') {
      unawaited(_exportCollection(collection));
    } else if (action == 'select') {
      _select(collection.jobs);
    } else {
      _batch(action, collection.jobs);
    }
  }

  Future<void> _exportCollection(DownloadCollection collection) async {
    try {
      await _exportCollectionFiles(collection);
    } catch (error) {
      if (mounted) _message(error.toString());
    }
  }

  void _showExportProgressDialog(MediaLibrary library) {
    if (!mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AnimatedBuilder(
          animation: library,
          builder: (context, _) => AlertDialog(
            title: const Text('正在导出'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: library.progress > 0 ? library.progress : null,
                ),
                const SizedBox(height: 12),
                Text(library.status),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => unawaited(library.cancel()),
                child: const Text('停止'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportCollectionFiles(DownloadCollection collection) async {
    final library = MediaLibrary.current;
    if (library == null) {
      _message('本地媒体尚未就绪，请稍候再试');
      return;
    }
    final jobs = collection.jobs.where((job) => job.completed).toList()
      ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    if (jobs.isEmpty) {
      _message('本剧还没有已下载的分集');
      return;
    }
    var directory = widget.store.exportDirectory;
    if (needsExportDirectorySelection(directory)) {
      directory = await pickExportDirectory() ?? '';
      if (directory.isEmpty || !mounted) return;
      try {
        await widget.store.setExportDirectory(directory);
      } catch (_) {}
    }
    while (true) {
      if (!mounted) return;
      final confirmed = await showDialog<Object>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导出到文件夹'),
          content: Text(
            '将把《${collection.drama.title}》已下载的 ${jobs.length} 集复制到：\n\n${exportDirectoryLabel(directory)}\n\n原始下载不受影响；目标已有同名文件时跳过。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'change'),
              child: const Text('更换位置'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始导出'),
            ),
          ],
        ),
      );
      if (confirmed == 'change') {
        directory = await pickExportDirectory() ?? '';
        if (directory.isEmpty || !mounted) return;
        try {
          await widget.store.setExportDirectory(directory);
        } catch (_) {}
        continue;
      }
      if (confirmed != true || !mounted) return;
      break;
    }
    _showExportProgressDialog(library);
    try {
      final result = await library.exportJobsToDirectory(jobs, directory);
      if (mounted) {
        _message(
          '已导出 ${result.exported} 集'
          '${result.skipped > 0 ? '，跳过 ${result.skipped} 集' : ''}',
        );
      }
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Widget _episode(DownloadJob job) => Padding(
    padding: const EdgeInsets.only(left: 12),
    child: Card(
      key: ValueKey('download-task-${job.id}'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: _selecting
                ? Checkbox(
                    value: _selected.contains(job.id),
                    onChanged: _busy ? null : (_) => _select([job]),
                  )
                : Icon(
                    job.completed
                        ? Icons.offline_pin_outlined
                        : job.state == 'failed'
                        ? Icons.error_outline
                        : Icons.downloading_rounded,
                  ),
            title: Text(
              '第 ${job.episode.number} 集${job.episode.vip ? ' · VIP' : ''}',
            ),
            subtitle: Text(
              '${job.archived ? '已保留视频' : job.stateLabel} · ${storageSize(job.bytes)}'
              '${job.actualQuality > 0 ? ' · ${job.actualQuality}P' : ''}${job.error.isNotEmpty ? '\n${job.error}' : ''}',
            ),
            onTap: _busy
                ? null
                : _selecting
                ? () => _select([job])
                : job.completed
                ? () => _play(job)
                : null,
            trailing: _selecting
                ? null
                : Builder(
                    builder: (menuContext) => IconButton(
                      tooltip: '分集操作',
                      onPressed: !_busy
                          ? () {
                              final anchor = glassMenuAnchor(menuContext);
                              if (anchor != null) {
                                unawaited(_openEpisodeMenu(job, anchor));
                              }
                            }
                          : null,
                      icon: const Icon(Icons.more_vert_rounded),
                    ),
                  ),
          ),
          if (!job.completed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: LinearProgressIndicator(
                value: job.progress > 0 || !job.active ? job.progress : null,
                minHeight: 2,
              ),
            ),
        ],
      ),
    ),
  );

  Future<void> _openEpisodeMenu(DownloadJob job, Rect anchor) async {
    final value = await showGlassMenu<String>(
      context: context,
      anchor: anchor,
      alignRight: true,
      entries: [
        if (job.completed)
          const GlassMenuEntry(
            value: 'play',
            label: Text('本地播放'),
            leading: Icon(Icons.play_circle_outline),
          ),
        if (job.active)
          const GlassMenuEntry(
            value: 'pause',
            label: Text('暂停'),
            leading: Icon(Icons.pause_circle_outline),
          ),
        if (job.resumable)
          const GlassMenuEntry(
            value: 'resume',
            label: Text('继续 / 重试'),
            leading: Icon(Icons.play_circle_outline),
          ),
        if (job.completed)
          GlassMenuEntry(
            value: job.archived ? 'restore' : 'archive',
            label: Text(job.archived ? '恢复任务' : '清理任务，保留视频'),
            leading: const Icon(Icons.archive_outlined),
          ),
        GlassMenuEntry(
          value: 'remove',
          label: Text(job.completed ? '删除视频' : '取消下载'),
          leading: const Icon(Icons.delete_outline),
        ),
      ],
    );
    if (!mounted || value == null) return;
    if (value == 'play') {
      unawaited(_play(job));
    } else {
      unawaited(_batch(value, [job]));
    }
  }

  Widget _batchBar() => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            if (_busy)
              TextButton(
                onPressed: () => setState(() => _stopBatch = true),
                child: const Text('停止批量操作'),
              )
            else ...[
              for (final entry in const {
                'pause': '暂停',
                'resume': '继续 / 重试',
                'archive': '保留视频',
                'remove': '删除',
              }.entries)
                TextButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => _batch(
                          entry.key,
                          _jobs.where((job) => _selected.contains(job.id)),
                        ),
                  child: Text(entry.value),
                ),
              if (_retryCommand != null)
                FilledButton(
                  onPressed: () => _batch(
                    _retryCommand!,
                    _jobs.where((job) => _selected.contains(job.id)),
                  ),
                  child: const Text('重试失败项'),
                ),
            ],
          ],
        ),
      ),
    ),
  );

  Iterable<DownloadJob> get _selectedJobs =>
      _jobs.where((job) => _selected.contains(job.id));

  Future<void> _televisionSearch() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) =>
          TelevisionSearchDialog(title: '搜索下载合集', initialValue: _search.text),
    );
    if (value == null || !mounted) return;
    setState(() => _search.text = value);
  }

  Future<void> _queueActions() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => const TelevisionActionDialog(
        title: '队列操作',
        options: [
          TelevisionAction(
            value: 'pause',
            label: '全部暂停',
            description: '暂停所有进行中的下载任务',
            icon: Icons.pause_rounded,
          ),
          TelevisionAction(
            value: 'resume',
            label: '全部继续',
            description: '继续或重试可恢复的任务',
            icon: Icons.play_arrow_rounded,
          ),
          TelevisionAction(
            value: 'archive',
            label: '清理已完成任务',
            description: '从任务列表移除，保留已下载视频',
            icon: Icons.archive_rounded,
          ),
          TelevisionAction(
            value: 'refresh',
            label: '刷新记录',
            description: '重新读取本机下载记录',
            icon: Icons.refresh_rounded,
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    if (value == 'refresh') {
      await _refresh();
    } else {
      await _batch(value, _jobs);
    }
  }

  Future<void> _collectionActions(DownloadCollection collection) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionActionDialog(
        title: collection.drama.title,
        options: [
          TelevisionAction(
            value: 'update',
            label: '更新本剧',
            description: '补充新增与缺失的分集',
            icon: Icons.cloud_download_rounded,
            enabled: !_updater.busy,
          ),
          const TelevisionAction(
            value: 'select',
            label: '选择本合集',
            description: '把整部剧加入多选',
            icon: Icons.checklist_rounded,
          ),
          const TelevisionAction(
            value: 'pause',
            label: '暂停本合集',
            icon: Icons.pause_rounded,
          ),
          const TelevisionAction(
            value: 'resume',
            label: '继续 / 重试本合集',
            icon: Icons.play_arrow_rounded,
          ),
          const TelevisionAction(
            value: 'archive',
            label: '清理已完成任务',
            description: '保留视频，从任务列表移除',
            icon: Icons.archive_rounded,
          ),
          if (_filter == 'archived')
            const TelevisionAction(
              value: 'restore',
              label: '恢复到任务列表',
              icon: Icons.unarchive_rounded,
            ),
          const TelevisionAction(
            value: 'remove',
            label: '取消任务并删除视频',
            icon: Icons.delete_outline_rounded,
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    if (value == 'update') {
      await _update(collection.drama);
    } else if (value == 'select') {
      _select(collection.jobs);
    } else {
      await _batch(value, collection.jobs);
    }
  }

  Future<void> _episodeActions(DownloadJob job) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionActionDialog(
        title: '第 ${job.episode.number} 集',
        options: [
          if (job.completed)
            const TelevisionAction(
              value: 'play',
              label: '本地播放',
              icon: Icons.play_circle_outline_rounded,
            ),
          if (job.active)
            const TelevisionAction(
              value: 'pause',
              label: '暂停',
              icon: Icons.pause_rounded,
            ),
          if (job.resumable)
            const TelevisionAction(
              value: 'resume',
              label: '继续 / 重试',
              icon: Icons.play_arrow_rounded,
            ),
          if (job.completed)
            TelevisionAction(
              value: job.archived ? 'restore' : 'archive',
              label: job.archived ? '恢复任务' : '清理任务，保留视频',
              icon: Icons.archive_rounded,
            ),
          TelevisionAction(
            value: 'remove',
            label: job.completed ? '删除视频' : '取消下载',
            icon: Icons.delete_outline_rounded,
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    if (value == 'play') {
      await _play(job);
    } else {
      await _batch(value, [job]);
    }
  }

  Widget _televisionToolbar(List<DownloadCollection> collections) {
    final actions = <(String, String, IconData, VoidCallback?)>[
      (
        'search',
        _search.text.isEmpty ? '搜索' : '搜索：${_search.text}',
        Icons.search_rounded,
        _televisionSearch,
      ),
      (
        'filter',
        _filter == 'all' && _release.isEmpty ? '筛选' : '筛选：已设置',
        Icons.filter_list_rounded,
        _filters,
      ),
      if (_selecting) ...[
        (
          'select-all',
          '全选',
          Icons.select_all_rounded,
          _busy ? null : () => _select(collections.expand((c) => c.jobs)),
        ),
        (
          'exit-select',
          '退出多选',
          Icons.close_rounded,
          _busy
              ? null
              : () => setState(() {
                  _selecting = false;
                  _selected.clear();
                  _retryCommand = null;
                }),
        ),
      ] else ...[
        (
          'select',
          '多选',
          Icons.checklist_rounded,
          _busy ? null : () => setState(() => _selecting = true),
        ),
        (
          'local',
          '本地媒体',
          Icons.video_library_outlined,
          () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => LocalMediaScreen(
                repository: widget.repository,
                store: widget.store,
              ),
            ),
          ),
        ),
        ('queue', '队列操作', Icons.tune_rounded, _busy ? null : _queueActions),
      ],
      ('refresh', '刷新', Icons.refresh_rounded, _refresh),
    ];
    return RemoteRow(
      key: _toolbarKey,
      itemKeys: [for (final action in actions) action.$1],
      autofocus: true,
      onExitDown: () => _listKey.currentState?.focusCurrent(),
      itemBuilder: (_, index, node, onFocus) => RemoteButton(
        key: ValueKey('tv-download-${actions[index].$1}'),
        label: actions[index].$2,
        icon: actions[index].$3,
        focusNode: node,
        onFocus: onFocus,
        onPressed: actions[index].$4,
      ),
    );
  }

  Widget _televisionBatchBar() {
    final actions = <(String, String, IconData, VoidCallback?)>[
      if (_busy)
        (
          'stop',
          '停止批量操作',
          Icons.stop_rounded,
          () => setState(() => _stopBatch = true),
        )
      else ...[
        (
          'pause',
          '暂停',
          Icons.pause_rounded,
          _selected.isEmpty ? null : () => _batch('pause', _selectedJobs),
        ),
        (
          'resume',
          '继续',
          Icons.play_arrow_rounded,
          _selected.isEmpty ? null : () => _batch('resume', _selectedJobs),
        ),
        (
          'archive',
          '保留视频',
          Icons.archive_rounded,
          _selected.isEmpty ? null : () => _batch('archive', _selectedJobs),
        ),
        (
          'remove',
          '删除',
          Icons.delete_outline_rounded,
          _selected.isEmpty ? null : () => _batch('remove', _selectedJobs),
        ),
        if (_retryCommand != null)
          (
            'retry',
            '重试失败项',
            Icons.refresh_rounded,
            () => _batch(_retryCommand!, _selectedJobs),
          ),
        (
          'exit-select',
          '退出多选',
          Icons.close_rounded,
          () => setState(() {
            _selecting = false;
            _selected.clear();
            _retryCommand = null;
          }),
        ),
      ],
    ];
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: RemoteRow(
            key: _batchKey,
            itemKeys: [for (final action in actions) action.$1],
            onExitUp: () => _listKey.currentState?.focusCurrent(),
            itemBuilder: (_, index, node, onFocus) => RemoteButton(
              key: ValueKey('tv-download-batch-${actions[index].$1}'),
              label: actions[index].$2,
              icon: actions[index].$3,
              focusNode: node,
              onFocus: onFocus,
              onPressed: actions[index].$4,
            ),
          ),
        ),
      ),
    );
  }

  Widget _collectionTile(
    DownloadCollection collection, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final count = collection.jobs
        .where((job) => _selected.contains(job.id))
        .length;
    final expanded = _expanded.contains(collection.drama.id);
    return RemoteListTile(
      title: collection.drama.title,
      subtitle:
          '${_selecting ? '$count/${collection.jobs.length} 集已选 · ' : ''}'
          '${collection.completed}/${collection.jobs.length} 集已下载 · ${storageSize(collection.bytes)}'
          '${collection.active > 0 ? ' · ${collection.active} 项进行中' : ''}'
          '${collection.failed > 0 ? ' · ${collection.failed} 项失败' : ''}'
          '${expanded ? ' · 已展开' : ' · 按确认展开分集'}',
      leading: Icon(
        expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
        size: 28,
      ),
      trailing: Icon(
        _selecting && count == collection.jobs.length
            ? Icons.check_circle_rounded
            : Icons.chevron_right_rounded,
        size: 24,
      ),
      focusNode: focusNode,
      onFocus: onFocus,
      onPressed: () {
        if (_selecting) {
          _select(collection.jobs);
          return;
        }
        setState(() {
          if (!_expanded.remove(collection.drama.id)) {
            _expanded.add(collection.drama.id);
          }
        });
      },
    );
  }

  Widget _episodeTile(
    DownloadJob job, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final selected = _selected.contains(job.id);
    return RemoteListTile(
      title: '第 ${job.episode.number} 集${job.episode.vip ? ' · VIP' : ''}',
      subtitle:
          '${_selecting ? '${selected ? '已选' : '未选'} · ' : ''}'
          '${job.archived ? '已保留视频' : job.stateLabel} · ${storageSize(job.bytes)}'
          '${job.actualQuality > 0 ? ' · ${job.actualQuality}P' : ''}'
          '${job.active ? ' · ${(job.progress * 100).round()}%' : ''}',
      leading: Icon(
        job.completed
            ? Icons.offline_pin_outlined
            : job.state == 'failed'
            ? Icons.error_outline
            : Icons.downloading_rounded,
        size: 28,
      ),
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
        size: 24,
      ),
      focusNode: focusNode,
      onFocus: onFocus,
      onPressed: _busy
          ? null
          : _selecting
          ? () => _select([job])
          : () => _episodeActions(job),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) {
      return const StatusPanel(title: '当前用户无权访问下载', message: '请返回后重新操作。');
    }
    final collections = _collections;
    final television = AppLayout.isTelevision(context);
    final rows = <Object>[
      for (final collection in collections) ...[
        collection,
        if (_expanded.contains(collection.drama.id)) ...[
          if (television) _CollectionMenu(collection),
          ...collection.jobs,
        ],
      ],
    ];
    final title = _selecting ? '已选 ${_selected.length} 项' : '下载合集';
    final actions = _titleActions(collections);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (!television) ...actions,
              ],
            ),
          ),
        if (television)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: _televisionToolbar(collections),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索剧名、站源或分类',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        onPressed: () => setState(_search.clear),
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          child: Text(
            '${collections.length} 部 · ${collections.fold<int>(0, (sum, c) => sum + c.jobs.length)} 集'
            '${_filter == 'archived' ? ' · 已清理任务，视频仍保留' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (_updater.busy || _busy) LinearProgressIndicator(minHeight: 2),
        if (_updater.busy || _busy)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _busy ? _operation : _updater.status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_updater.busy)
                  TextButton(
                    onPressed: _updater.cancel,
                    child: const Text('停止'),
                  ),
              ],
            ),
          ),
        if (_error != null && _jobs.isNotEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _jobs.isEmpty
              ? StatusPanel(
                  title: '无法读取下载记录',
                  message: _error!,
                  onRetry: _refresh,
                )
              : rows.isEmpty
              ? StatusPanel(
                  title: _jobs.isEmpty ? '还没有下载任务' : '暂无符合条件的任务',
                  message: '在剧集详情选择下载，或调整筛选查看已保留的视频。',
                  icon: Icons.download_outlined,
                )
              : television
              ? RemoteList(
                  key: _listKey,
                  itemKeys: [
                    for (var index = 0; index < rows.length; index++)
                      switch (rows[index]) {
                        DownloadCollection collection =>
                          'c-${collection.drama.id}',
                        DownloadJob job => 'j-${job.id}',
                        _CollectionMenu menu => 'm-${menu.collection.drama.id}',
                        _ => 'row-$index',
                      },
                  ],
                  itemExtent: RemoteListTile.extent,
                  spacing: 8,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  onExitUp: () => _toolbarKey.currentState?.focusCurrent(),
                  onExitDown: _selecting
                      ? () => _batchKey.currentState?.focusCurrent()
                      : null,
                  itemBuilder: (_, index, node, onFocus) =>
                      switch (rows[index]) {
                        DownloadCollection collection => _collectionTile(
                          collection,
                          focusNode: node,
                          onFocus: onFocus,
                        ),
                        DownloadJob job => _episodeTile(
                          job,
                          focusNode: node,
                          onFocus: onFocus,
                        ),
                        _CollectionMenu menu => RemoteListTile(
                          title: '合集操作',
                          subtitle: '更新本剧、选择、暂停、继续、清理或删除整部剧',
                          leading: const Icon(
                            Icons.more_horiz_rounded,
                            size: 26,
                          ),
                          focusNode: node,
                          onFocus: onFocus,
                          onPressed: () => _collectionActions(menu.collection),
                        ),
                        _ => const SizedBox.shrink(),
                      },
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    4,
                    12,
                    widget.embedded &&
                            widget.store.interfaceStyle == 'glass' &&
                            !AppLayout.isTelevision(context)
                        ? GlassBottomNavigation.contentInset +
                              MediaQuery.paddingOf(context).bottom +
                              20
                        : 20,
                  ),
                  itemCount: rows.length,
                  itemBuilder: (_, index) => switch (rows[index]) {
                    DownloadCollection collection => _collection(collection),
                    DownloadJob job => _episode(job),
                    _ => const SizedBox.shrink(),
                  },
                ),
        ),
        if (_selecting) television ? _televisionBatchBar() : _batchBar(),
      ],
    );
    if (widget.embedded) return body;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: AppLayout.isTelevision(context) ? null : actions,
        ),
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}
