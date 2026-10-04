import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'catalog_sort.dart';
import 'core_bridge.dart';
import 'drama_actions.dart';
import 'follow_state.dart';
import 'local_store.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';

class SavedLibrary extends StatefulWidget {
  const SavedLibrary({
    super.key,
    required this.repository,
    required this.store,
    required this.history,
    required this.onOpen,
    required this.onContinue,
    this.onDownload,
    this.remoteAutofocus = false,
    this.onExitLeft,
    this.onExitUp,
  });

  final AppRepository repository;
  final LocalStore store;
  final bool history;
  final ValueChanged<Drama> onOpen;
  final ValueChanged<Drama> onContinue;
  final ValueChanged<Drama>? onDownload;
  final bool remoteAutofocus;
  final VoidCallback? onExitLeft;
  final VoidCallback? onExitUp;

  @override
  State<SavedLibrary> createState() => _SavedLibraryState();
}

class _SavedLibraryState extends State<SavedLibrary> {
  final _search = TextEditingController();
  final _tvDeleteFocus = FocusNode();
  String _filter = '';
  bool _selecting = false;
  final _selectedIds = <String>{};

  @override
  void dispose() {
    _search.dispose();
    _tvDeleteFocus.dispose();
    super.dispose();
  }

  void _enterSelection([String? initialId]) {
    setState(() {
      _selecting = true;
      if (initialId != null) {
        _selectedIds.add(initialId);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleSelectAll(List<Drama> visibleItems) {
    setState(() {
      final visibleIds = visibleItems.map((d) => d.id).toSet();
      if (_selectedIds.containsAll(visibleIds)) {
        _selectedIds.removeAll(visibleIds);
      } else {
        _selectedIds.addAll(visibleIds);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 $count 条观看记录？'),
        content: Text('这会删除已勾选的 $count 部短剧观看记录，追剧状态不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      final toRemove = _selectedIds.toList();
      await saveUserChange(
        context,
        () => widget.store.removeHistories(toRemove),
      );
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selecting = false;
        });
      }
    }
  }

  Future<void> _clearHistory() async {
    final epoch = widget.store.profileEpoch;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('这会删除当前用户的观看进度，追剧状态和手动已看标记会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted && epoch == widget.store.profileEpoch) {
      await saveUserChange(context, widget.store.clearHistory);
    }
  }

  void _actions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    history: widget.history,
    onContinue: () => widget.onContinue(drama),
    onDownload: widget.onDownload == null
        ? null
        : () => widget.onDownload!(drama),
    onSelectHistory: widget.history ? () => _enterSelection(drama.id) : null,
  );

  Widget _tile(Drama drama, {FocusNode? focusNode, VoidCallback? onFocus}) {
    final watched = widget.store.watched(drama.id);
    final state = widget.store.following(drama.id);
    final badge = state == null
        ? null
        : '${state.label}${state.hasUpdates ? ' · ${state.updateLabel}' : ''}';
    final isSelecting = widget.history && _selecting;
    final isSelected = isSelecting ? _selectedIds.contains(drama.id) : null;
    final onTileTap = isSelecting
        ? () => _toggleSelection(drama.id)
        : () => widget.onOpen(drama);
    final onLongPress = widget.history && !_selecting
        ? () => _enterSelection(drama.id)
        : null;
    final actionButton = isSelecting
        ? null
        : DramaActionButton(
            drama: drama,
            onPressed: () => _actions(drama),
          );
    return DramaTile(
      key: ValueKey('saved-${drama.id}'),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      selected: isSelected,
      onTap: onTileTap,
      onMore: isSelecting ? null : () => _actions(drama),
      onLongPress: onLongPress,
      actions: actionButton,
      badge: badge,
      subtitle: watched == null
          ? SourceSite.byId(drama.source).name
          : '第 ${watched.episode} 集 · ${formatPosition(watched.position)}',
    );
  }

  Widget _selectionBar() {
    final theme = Theme.of(context);
    final count = _selectedIds.length;
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 0 ? '点选要删除的短剧' : '已选择 $count 部',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '可批量清理观看记录',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('delete-selected-history'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: count > 0 ? _deleteSelected : null,
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                label: Text(count == 0 ? '删除' : '删除 ($count)'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tvSelectionBar() {
    final count = _selectedIds.length;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '已选择 $count 部观看记录',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              RemoteButton(
                key: const ValueKey('tv-delete-selected-history'),
                label: count == 0 ? '删除' : '删除 ($count)',
                icon: Icons.delete_outline_rounded,
                focusNode: _tvDeleteFocus,
                onPressed: count > 0 ? _deleteSelected : null,
              ),
              const SizedBox(width: 8),
              RemoteButton(
                key: const ValueKey('tv-cancel-history-selection'),
                label: '退出多选',
                icon: Icons.close_rounded,
                onPressed: _exitSelection,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final history = widget.store.history;
      final all = widget.history
          ? history.map((entry) => entry.drama).toList()
          : widget.store.favorites;
      final items = all.where((drama) {
        if (!matchesDramaQuery(drama, _search.text)) return false;
        final state = widget.store.following(drama.id);
        return widget.history ||
            _filter.isEmpty ||
            (_filter == 'updates'
                ? state?.hasUpdates == true
                : state?.status.name == _filter);
      }).toList();
      final ids = items.map((drama) => drama.id).toSet();
      final inSelection = widget.history && _selecting;
      final title = inSelection
          ? '已选择 ${_selectedIds.length} 项'
          : '${widget.history ? '最近观看' : '我的追剧'} · ${all.length}';
      final allSelected =
          items.isNotEmpty && _selectedIds.containsAll(items.map((e) => e.id));
      final tvExitDown =
          inSelection ? () => _tvDeleteFocus.requestFocus() : null;
      final resume = inSelection
          ? null
          : history
              .where(
                (entry) =>
                    ids.contains(entry.drama.id) &&
                    (!entry.finished ||
                        entry.drama.episodes <= 0 ||
                        entry.episode < entry.drama.episodes),
              )
              .firstOrNull;
      final header = [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (inSelection) ...[
                TextButton(
                  key: const ValueKey('history-select-all'),
                  onPressed: items.isEmpty
                      ? null
                      : () => _toggleSelectAll(items),
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
                TextButton(
                  key: const ValueKey('history-cancel-selection'),
                  onPressed: _exitSelection,
                  child: const Text('取消'),
                ),
              ] else if (widget.history && all.isNotEmpty) ...[
                IconButton(
                  key: const ValueKey('select-history'),
                  tooltip: '批量删除',
                  onPressed: () => _enterSelection(),
                  icon: const Icon(Icons.checklist_rounded),
                ),
                IconButton(
                  tooltip: '清空观看记录',
                  onPressed: _clearHistory,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            key: ValueKey(
              widget.history ? 'history-search' : 'favorites-search',
            ),
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: widget.history ? '搜索观看记录' : '搜索追剧',
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
        if (!widget.history)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                for (final filter in [
                  ('', '全部'),
                  for (final status in FollowStatus.values)
                    (status.name, status.label),
                  ('updates', '有更新'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('follow-filter-${filter.$1}'),
                      label: Text(filter.$2),
                      selected: _filter == filter.$1,
                      onSelected: (_) => setState(() => _filter = filter.$1),
                    ),
                  ),
              ],
            ),
          ),
        if (resume != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                key: const ValueKey('continue-watching'),
                leading: const Icon(Icons.play_circle_outline),
                title: Text(
                  '继续观看 · ${resume.drama.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '第 ${resume.episode} 集 · ${formatPosition(resume.position)}',
                ),
                onTap: () => widget.onContinue(resume.drama),
              ),
            ),
          ),
      ];
      final empty = StatusPanel(
        title: all.isEmpty
            ? widget.history
                  ? '还没有观看记录'
                  : '还没有追剧'
            : '没有匹配的记录',
        message: all.isEmpty ? '去发现页，挑一部喜欢的短剧。' : '可以更换搜索词或筛选条件。',
        icon: widget.history
            ? Icons.history_rounded
            : Icons.bookmark_border_rounded,
      );
      final content = LayoutBuilder(
        builder: (context, constraints) {
          if (AppLayout.isTelevision(context)) {
            final columns = ((constraints.maxWidth - 36) / 150).floor().clamp(
              1,
              8,
            );
            final tileWidth =
                (constraints.maxWidth - 36 - (columns - 1) * 14) / columns;
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .5,
                  ),
                  child: SingleChildScrollView(child: Column(children: header)),
                ),
                Expanded(
                  child: items.isEmpty
                      ? empty
                      : RemoteGrid(
                          key: ValueKey(
                            'saved-tv-${widget.history}-$_filter-${_search.text}',
                          ),
                          itemKeys: items.map((item) => item.id).toList(),
                          columns: columns,
                          itemExtent:
                              DramaTile.extentFor(context, tileWidth - 14) + 14,
                          autofocus: widget.remoteAutofocus,
                          onExitLeft: widget.onExitLeft,
                          onExitUp: widget.onExitUp,
                          onExitDown: tvExitDown,
                          itemBuilder: (_, index, node, onFocus) => _tile(
                            items[index],
                            focusNode: node,
                            onFocus: onFocus,
                          ),
                        ),
                ),
              ],
            );
          }
          final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
          return CustomScrollView(
            key: PageStorageKey(
              'saved-${widget.history}-$_filter-${_search.text}',
            ),
            slivers: [
              SliverToBoxAdapter(child: Column(children: header)),
              if (items.isEmpty)
                SliverFillRemaining(hasScrollBody: false, child: empty)
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, 20),
                  sliver: SliverGrid(
                    gridDelegate: dramaGridDelegate(
                      context,
                      constraints.maxWidth - 2 * padding,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => _tile(items[index]),
                      childCount: items.length,
                    ),
                  ),
                ),
            ],
          );
        },
      );
      if (!inSelection) return content;
      final bottomBar = AppLayout.isTelevision(context)
          ? _tvSelectionBar()
          : _selectionBar();
      final body = Column(
        children: [
          Expanded(child: content),
          bottomBar,
        ],
      );
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exitSelection();
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _exitSelection,
          },
          child: body,
        ),
      );
    },
  );
}
