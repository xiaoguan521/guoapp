import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'app_update.dart';
import 'app_bottom_navigation.dart';
import 'app_notice.dart';
import 'glass_panel.dart';
import 'core_bridge.dart';
import 'catalog_filters.dart';
import 'catalog_browser.dart';
import 'catalog_prefetch.dart';
import 'catalog_sort.dart';
import 'catalog_sort_sheet.dart';
import 'catalog_view_cache.dart';
import 'feeds_screen.dart';
import 'form_text_field.dart';
import 'recommendation_service.dart';
import 'recommendations_screen.dart';
import 'rankings_screen.dart';
import 'detail_screen.dart';
import 'playback_launch_screen.dart';
import 'downloads_screen.dart';
import 'local_store.dart';
import 'lan_screen.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'vip_icon.dart';
import 'settings_screen.dart';
import 'profiles_screen.dart';
import 'search_input.dart';
import 'search_cache.dart';
import 'sources_screen.dart';
import 'batch_download_screen.dart';
import 'batch_downloads.dart';
import 'drama_actions.dart';
import 'library_updater.dart';
import 'live_repository.dart';
import 'live_screen.dart';
import 'live_store.dart';
import 'saved_library.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _recommendationCategory = 'app:recommendations';
  static const _tabDiscover = 0;
  static const _tabFeed = 1;
  static const _tabFollow = 2;
  static const _tabHistory = 3;
  static const _tabLive = 4;
  static const _tabDownloads = 5;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _prefetch = CatalogPrefetchScheduler();
  final _viewCache = CatalogViewCache();
  Timer? _debounce;
  late SourceSite _source;
  bool _allSources = false;
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  int _tab = _tabDiscover;
  String _submittedQuery = '';
  final _categorySelections = <String, String>{};
  late final CatalogBrowser _browser;
  bool _searchVisible = false;
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;
  late final LibraryUpdater _updater;
  final _changedSources = <String>{};
  final _selectedDramas = <String, Drama>{};
  Timer? _cacheRefreshTimer;
  Timer? _progressTimer;
  bool _progressRequestActive = false;
  bool _refreshingUpdatedCache = false;
  bool _selectionMode = false;
  bool _showRecommendations = false;
  bool _catalogLoadScheduled = false;
  bool _backToTopVisible = false;
  bool _bottomBarHidden = false;
  double _lastCatalogPixels = 0;
  final _filtersKey = GlobalKey<RemoteRowState>();
  final _gridKey = GlobalKey<RemoteGridState>();
  final _navKey = GlobalKey<RemoteListState>();
  final _appBarFocus = FocusNode(debugLabel: 'tv-appbar');
  final _sourceMenuKey = GlobalKey(debugLabel: 'source-menu-anchor');
  final _moreMenuKey = GlobalKey(debugLabel: 'more-menu-anchor');
  final _selectionFocus = FocusNode(debugLabel: 'tv-selection');
  late final LiveRepository _liveRepository = LiveRepository();
  late final LiveStore _liveStore = LiveStore(
    widget.store.preferences,
    widget.store.profile.id,
  )..load();

  List<SourceGroup> get _sourceGroups {
    final groups = SourceGroup.fromSources(widget.store.sources);
    return [
      if (groups.length > 1) SourceGroup('all', '全部', widget.store.sources),
      ...groups,
    ];
  }

  SourceGroup get _group =>
      _sourceGroups
          .where((group) => group.id == (_allSources ? 'all' : _source.groupId))
          .firstOrNull ??
      SourceGroup(_source.groupId, _source.groupName, [_source]);
  bool get _onlineSearch => _group.sources.any((source) => source.onlineSearch);
  bool get _searchSuggestions =>
      _group.sources.any((source) => source.searchSuggestions);
  String get _searchHint {
    final online = _group.sources
        .where((source) => source.onlineSearch)
        .toList();
    if (online.isEmpty) {
      return '筛选本机已更新剧库';
    }
    final names = online.map((source) => source.name).join('、');
    return online.length == _group.sources.length
        ? '搜索$names'
        : '搜索$names及本机剧库';
  }

  String get _category => _categorySelections[_group.id] ?? '';
  List<CatalogCategory> get _categories => _browser.categories(_group);
  String get _displayCategory =>
      _showRecommendations ? _recommendationCategory : _category;
  List<CatalogCategory> get _displayCategories => [
    CatalogCategory.all,
    if (_group.id == 'hongguo')
      const CatalogCategory(_recommendationCategory, '推荐'),
    ..._categories.where((entry) => entry.id.isNotEmpty),
  ];

  Future<void> _loadCategories({
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final group = _group;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    final error = await _browser.loadCategories(
      group,
      force: force,
      cacheOnly: cacheOnly,
    );
    if (!mounted ||
        generation != _categoryGeneration ||
        group.id != _group.id) {
      return;
    }
    setState(() {
      _categoriesLoading = false;
      _categoriesError = error;
    });
    if (!_showRecommendations &&
        _category.isNotEmpty &&
        !_categories.any((entry) => entry.id == _category)) {
      _changeCategory('');
    }
  }

  Future<void> _refreshCatalog() async {
    if (widget.repository.supportsSourceManagement) {
      if (_group.sources.any((source) => _updater.busy(source.id))) return;
      _pauseCatalog();
      await _updater.update(_group.sources);
      return;
    }
    await _loadCategories(force: true);
    if (mounted) await _load(force: true);
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  void _catalogUpdated(String source) {
    if (!mounted) return;
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_reloadUpdatedCache());
    });
  }

  Future<void> _reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    final epoch = widget.store.profileEpoch;
    try {
      while (mounted &&
          _changedSources.isNotEmpty &&
          epoch == widget.store.profileEpoch) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!widget.store.allowsSource(source)) continue;
          try {
            final cached = await widget.repository.cached(source);
            for (final drama in cached.items) {
              if (widget.store.allowsSource(drama.source)) {
                updates[drama.id] = drama;
              }
            }
          } catch (error) {
            if (mounted && epoch == widget.store.profileEpoch) {
              setState(() => _error = '更新后读取缓存失败：$error');
            }
          }
        }
        if (!mounted || epoch != widget.store.profileEpoch) return;
        _browser.updateDramas(updates.values);
        setState(() {
          _items = [
            for (final item in _items)
              updates[item.id] == null ? item : item.merge(updates[item.id]!),
          ];
          for (final id in _selectedDramas.keys.toList()) {
            if (updates[id] != null) {
              _selectedDramas[id] = _selectedDramas[id]!.merge(updates[id]!);
            }
          }
        });
        await saveUserChange(
          context,
          () => widget.store.refreshDramas(updates.values),
        );
        if (!mounted || epoch != widget.store.profileEpoch) return;
        if (_group.sources.any((source) => sources.contains(source.id))) {
          await _loadCategories(cacheOnly: true);
          if (mounted &&
              !_loading &&
              !_loadingMore &&
              (!_onlineSearch || _search.text.trim().isEmpty)) {
            await _load(cacheOnly: true);
          }
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  void _changeGroup(SourceGroup group) {
    if (_group.id != group.id) {
      _changeSource(group.sources.first, allSources: group.id == 'all');
    }
  }

  void _changeCategory(String category) {
    if (category == _recommendationCategory && _group.id == 'hongguo') {
      if (_showRecommendations) return;
      _pauseCatalog();
      setState(() {
        _showRecommendations = true;
        _selectionMode = false;
        _selectedDramas.clear();
        _search.clear();
        _searchVisible = false;
        _submittedQuery = '';
      });
      return;
    }
    if (_category == category && !_showRecommendations) return;
    _debounce?.cancel();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _categorySelections[_group.id] = category;
      if (_onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  void _swipeCategory(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 240) return;
    final categories = _displayCategories;
    final index = categories.indexWhere(
      (entry) => entry.id == _displayCategory,
    );
    final next = index + (velocity < 0 ? 1 : -1);
    if (next >= 0 && next < categories.length) {
      _changeCategory(categories[next].id);
    }
  }

  void _toggleSearch() {
    if (AppLayout.isTelevision(context)) {
      _televisionSearch();
      return;
    }
    if (_showRecommendations) _changeCategory('');
    final hadQuery = _search.text.isNotEmpty;
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) _search.clear();
    });
    if (!_searchVisible && hadQuery) _searchChanged('');
  }

  void _openRankings() {
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialGroup: _group.id,
        ),
      ),
    );
  }

  Future<void> _manageSources() async {
    _pauseCatalog();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcesScreen(
          repository: widget.repository,
          store: widget.store,
          initialSource: _source.id,
        ),
      ),
    );
    if (!mounted) return;
    await _loadCategories();
    if (mounted && (!_onlineSearch || _submittedQuery.isEmpty)) {
      await _load(useCache: true);
    }
  }

  Rect? _anchorRect(GlobalKey key) {
    final anchorContext = key.currentContext;
    final object = anchorContext?.findRenderObject();
    if (anchorContext == null || object is! RenderBox) return null;
    final overlay = Overlay.of(anchorContext).context.findRenderObject();
    if (overlay is! RenderBox) return null;
    return MatrixUtils.transformRect(
      object.getTransformTo(overlay),
      Offset.zero & object.size,
    );
  }

  Future<void> _openSourceMenu() async {
    if (_sourceGroups.length <= 1) return;
    final anchor = _anchorRect(_sourceMenuKey);
    if (anchor == null) return;
    final group = await showGlassMenu<SourceGroup>(
      context: context,
      anchor: anchor,
      autofocusSelected: AppLayout.isTelevision(context),
      entries: [
        for (final entry in _sourceGroups)
          GlassMenuEntry(
            value: entry,
            label: Text(entry.name),
            selected: entry.id == _group.id,
            trailing: entry.id == _group.id
                ? Icon(
                    Icons.check_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
          ),
      ],
    );
    if (group != null && mounted) _changeGroup(group);
  }

  Future<void> _openMoreMenu(double maxWidth) async {
    final anchor = _anchorRect(_moreMenuKey);
    if (anchor == null) return;
    final showUpdate =
        _tab == _tabDiscover && !_showRecommendations && maxWidth < 400;
    final action = await showGlassMenu<String>(
      context: context,
      anchor: anchor,
      alignRight: true,
      autofocusSelected: AppLayout.isTelevision(context),
      entries: [
        if (showUpdate)
          GlassMenuEntry(
            value: 'update',
            label: const Text('更新剧库'),
            leading: const Icon(Icons.cloud_sync_outlined),
            enabled:
                widget.store.sources.isNotEmpty &&
                !_group.sources.any((source) => _updater.busy(source.id)),
          ),
        const GlassMenuEntry(
          value: 'follow',
          label: Text('追剧'),
          leading: Icon(Icons.bookmark_rounded),
        ),
        if (widget.repository.supportsSourceManagement)
          const GlassMenuEntry(
            value: 'sources',
            label: Text('站源管理'),
            leading: Icon(Icons.travel_explore_rounded),
          ),
        const GlassMenuEntry(
          value: 'users',
          label: Text('用户管理'),
          leading: Icon(Icons.manage_accounts_outlined),
        ),
        const GlassMenuEntry(
          value: 'settings',
          label: Text('设置与备份'),
          leading: Icon(Icons.settings_outlined),
        ),
        const GlassMenuEntry(
          value: 'display',
          label: Text('界面模式'),
          leading: Icon(Icons.monitor_rounded),
        ),
        GlassMenuEntry(
          value: 'about',
          label: Text('关于${appEditionName(widget.store.fullMode)}'),
          leading: const Icon(Icons.info_outline_rounded),
        ),
      ],
    );
    _handleMoreAction(action);
  }

  void _handleMoreAction(String? action) {
    if (action == null || !mounted) return;
    if (action == 'update') {
      _refreshCatalog();
    } else if (action == 'follow') {
      _changeTab(_tabFollow);
    } else if (action == 'sources') {
      _manageSources();
    } else if (action == 'users') {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ProfilesScreen(store: widget.store),
        ),
      );
    } else if (action == 'settings') {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            repository: widget.repository,
            store: widget.store,
            onLibraryChanged: (sources) {
              for (final source in sources) {
                _catalogUpdated(source);
              }
            },
          ),
        ),
      );
    } else if (action == 'display') {
      _chooseDisplayMode();
    } else if (action == 'about') {
      showDialog<void>(
        context: context,
        builder: (_) =>
            _AboutDialog(store: widget.store, repository: widget.repository),
      );
    }
  }

  Future<void> _chooseDisplayMode() async {
    final selection = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('界面模式'),
        children: [
          RadioGroup<String>(
            groupValue: widget.store.displayMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in const {
                  'auto': '自动识别设备',
                  'television': '电视 / 遥控器',
                  'standard': '手机 / 电脑',
                }.entries)
                  RadioListTile<String>(
                    value: mode.key,
                    autofocus: mode.key == widget.store.displayMode,
                    title: Text(mode.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selection != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setDisplayMode(selection),
      );
    }
  }

  Future<void> _televisionSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: _group.id == 'all'
            ? '搜索已开放站源'
            : _onlineSearch
            ? '搜索${_group.name}短剧'
            : '筛选当前已加载短剧',
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        suggestions: _searchSuggestions ? widget.repository.suggestions : null,
      ),
    );
    if (query != null && mounted) {
      _submitSearch(query);
    }
  }

  void _televisionBack() {
    if (_selectionMode) {
      _cancelSelection();
    } else if (_tab != _tabDiscover) {
      setState(() => _tab = 0);
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onCatalogScroll);
    _prefetch.onIdle = () => unawaited(_prefetchCatalog());
    _source = SourceSite.byId(widget.store.source);
    _allSources = widget.store.catalogView.allSources;
    _browser = CatalogBrowser(widget.repository);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    RecommendationService.current?.attach(widget.store);
    if (widget.store.sources.isNotEmpty) {
      _load(useCache: true);
      _loadCategories();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    RecommendationService.current?.detach();
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _cacheRefreshTimer?.cancel();
    _stopProgressPolling();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    _debounce?.cancel();
    _search.dispose();
    _scroll.removeListener(_onCatalogScroll);
    _prefetch.dispose();
    _scroll.dispose();
    _appBarFocus.dispose();
    _selectionFocus.dispose();
    _liveRepository.dispose();
    _liveStore.dispose();
    super.dispose();
  }

  void _onCatalogScroll() {
    if (mounted && _scroll.hasClients) {
      _prefetch.scrolled(
        extentAfter: _scroll.position.extentAfter,
        viewport: _scroll.position.viewportDimension,
      );
    }
    if (mounted &&
        _scroll.hasClients &&
        widget.store.interfaceStyle == 'glass' &&
        _tab == _tabDiscover &&
        !AppLayout.isTelevision(context)) {
      final pixels = _scroll.position.pixels;
      final delta = pixels - _lastCatalogPixels;
      if (delta != 0) _lastCatalogPixels = pixels;
      var hidden = _bottomBarHidden;
      if (delta > 6 && pixels > 120) {
        hidden = true;
      } else if (delta < -6 || pixels <= 120) {
        hidden = false;
      }
      final visible = pixels > 320;
      if (hidden != _bottomBarHidden || visible != _backToTopVisible) {
        setState(() {
          _bottomBarHidden = hidden;
          _backToTopVisible = visible;
        });
      }
    }
    if (!mounted ||
        _showRecommendations ||
        !_hasMore ||
        _loading ||
        _loadingMore ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.5).clamp(320.0, 900.0);
    if (position.extentAfter > threshold || _catalogLoadScheduled) return;
    _catalogLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _catalogLoadScheduled = false;
      if (!mounted ||
          _showRecommendations ||
          !_hasMore ||
          _loading ||
          _loadingMore ||
          !_scroll.hasClients) {
        return;
      }
      unawaited(_load(more: true));
    });
  }

  bool get _canPrefetch =>
      mounted &&
      _tab == _tabDiscover &&
      !_showRecommendations &&
      _hasMore &&
      !_loading &&
      !_loadingMore &&
      _scroll.hasClients;

  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _schedulePrefetch() {
    if (!mounted || !_scroll.hasClients) return;
    _prefetch.settled(
      extentAfter: _scroll.position.extentAfter,
      viewport: _scroll.position.viewportDimension,
    );
  }

  Future<void> _prefetchCatalog() async {
    if (!_canPrefetch) return;
    await _load(more: true);
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _browser.updateDrama(drama);
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  CatalogPage? _cachedSearch(SourceGroup group, String query) {
    final entries = [
      for (final source in group.sources)
        SearchResultCache.instance.read(source.id, query, allowStale: true),
    ].whereType<SearchCacheEntry>().toList();
    if (entries.isEmpty) return null;
    final items = <String, Drama>{};
    for (final entry in entries) {
      for (final drama in entry.items) {
        items[drama.id] = drama;
      }
    }
    return CatalogPage(
      items.values.toList(),
      hasMore: entries.any((entry) => entry.hasMore),
      warning: entries
          .map((entry) => entry.warning)
          .where((warning) => warning.isNotEmpty)
          .toSet()
          .join('；'),
      fresh:
          entries.length == group.sources.length &&
          entries.every((entry) => entry.fresh),
    );
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (_showRecommendations) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final group = _group;
    final query = _onlineSearch ? _search.text.trim() : '';
    setState(() {
      _error = null;
      if (query.isNotEmpty) _categorySelections[group.id] = '';
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery) _items = [];
      }
    });
    void accept(
      CatalogPage result, {
      bool cached = false,
      bool partial = false,
      bool updateLibrary = true,
    }) {
      if (!mounted || generation != _generation) return;
      if (partial && result.items.length <= _items.length) return;
      setState(() {
        _items = result.items;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        _loading = partial || (cached && !result.fresh);
        _loadingMore = false;
        _error = partial
            ? null
            : (result.warning.isEmpty ? null : result.warning);
      });
      if (partial) return;
      if (query.isNotEmpty && !cached) {
        final bySource = <String, List<Drama>>{};
        for (final drama in result.items) {
          (bySource[drama.source] ??= []).add(drama);
        }
        for (final entry in bySource.entries) {
          SearchResultCache.instance.writeItems(
            source: entry.key,
            query: query,
            items: entry.value,
            total: entry.value.length,
            hasMore: result.hasMore,
            warning: result.warning,
          );
        }
      }
      if (updateLibrary) {
        unawaited(
          saveUserChange(
            context,
            () => widget.store.refreshDramas(result.items),
          ),
        );
      }
    }

    if (query.isNotEmpty && !more) {
      _startProgressPolling(group, query, generation);
    }
    final cachedSearch = query.isNotEmpty && !more && !force
        ? _cachedSearch(group, query)
        : null;
    if (cachedSearch != null) {
      accept(cachedSearch, cached: true, updateLibrary: false);
      if (cachedSearch.fresh && !cachedSearch.hasMore) {
        _stopProgressPolling();
        return;
      }
    }
    try {
      final result = await _browser.load(
        group,
        category: _category,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result, cached: true),
        onPartial: (result) => accept(result, partial: true),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
      });
    } finally {
      if (generation == _generation) _stopProgressPolling();
    }
    _schedulePrefetch();
  }

  void _startProgressPolling(SourceGroup group, String query, int generation) {
    _stopProgressPolling();
    final source = group.sources.first.id;
    _progressTimer = Timer.periodic(const Duration(milliseconds: 700), (
      timer,
    ) async {
      if (!mounted || generation != _generation) {
        _stopProgressPolling();
        return;
      }
      if (_progressRequestActive) return;
      _progressRequestActive = true;
      try {
        final page = await widget.repository.searchProgress(source, query);
        if (!mounted || generation != _generation || !timer.isActive) return;
        if (page.items.isEmpty || page.items.length <= _items.length) return;
        setState(() {
          _items = page.items;
          _submittedQuery = query;
          _loading = true;
          _error = null;
        });
      } catch (_) {
      } finally {
        _progressRequestActive = false;
      }
    });
  }

  void _stopProgressPolling() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _changeSource(SourceSite source, {bool allSources = false}) {
    if (_source.id == source.id && _allSources == allSources) {
      return;
    }
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _source = source;
      _allSources = allSources;
      _items = [];
      _hasMore = true;
      _submittedQuery = '';
      _error = null;
    });
    unawaited(
      saveUserChange(
        context,
        () => widget.store.setCatalogSource(source.id, allSources: allSources),
      ),
    );
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    _load(useCache: true);
    _loadCategories();
  }

  void _searchChanged(String query) {
    _debounce?.cancel();
    _selectionMode = false;
    _selectedDramas.clear();
    if (_onlineSearch && (_loading || _loadingMore)) {
      _generation++;
      unawaited(_browser.cancel());
      _loading = _loadingMore = false;
    }
    setState(() {});
    if (_onlineSearch && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _load());
    }
  }

  void _submitSearch(String query) {
    if (_showRecommendations) {
      _showRecommendations = false;
      _categorySelections[_group.id] = '';
    }
    _selectionMode = false;
    _selectedDramas.clear();
    _search.text = query.trim();
    _debounce?.cancel();
    if (_search.text.isNotEmpty) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.rememberSearch(_search.text),
        ),
      );
    }
    if (_onlineSearch) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _chooseCatalogView() async {
    final selected = await chooseCatalogView(context, widget.store.catalogView);
    if (selected != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setCatalogView(selected),
      );
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  void _openDrama(Drama drama, {bool resume = false, bool download = false}) {
    _pauseCatalog();
    if (download) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DetailScreen(
            drama: drama,
            repository: widget.repository,
            store: widget.store,
            downloadOnOpen: true,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackLaunchScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
          searchKeyword: _onlineSearch ? _submittedQuery : '',
        ),
      ),
    );
  }

  void _changeTab(int tab) {
    if (tab == _tabDiscover) {
      _prefetch.resume();
      WidgetsBinding.instance.addPostFrameCallback((_) => _schedulePrefetch());
    } else {
      _prefetch.hold();
    }
    setState(() {
      _tab = tab;
      _selectionMode = false;
      _bottomBarHidden = false;
      _selectedDramas.clear();
    });
  }

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _selectDrama(Drama drama) {
    if (!widget.store.canDownload ||
        !widget.repository.supportsDownloads ||
        !widget.store.allowsSource(drama.source)) {
      return;
    }
    if (!_selectedDramas.containsKey(drama.id) &&
        _selectedDramas.length >= BatchDownloads.maxDramas) {
      AppNotice.show(context, '一次最多选择 50 部短剧，请分批下载');
      return;
    }
    setState(() {
      _selectionMode = true;
      if (_selectedDramas.remove(drama.id) == null) {
        _selectedDramas[drama.id] = drama;
      }
    });
  }

  void _downloadSelected() {
    if (!widget.store.canDownload || _selectedDramas.isEmpty) return;
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BatchDownloadScreen(
          repository: widget.repository,
          store: widget.store,
          dramas: _selectedDramas.values.toList(),
        ),
      ),
    );
  }

  Future<void> _refreshCover(Drama drama) async {
    try {
      await widget.repository.cover(drama, force: true, refresh: true);
      if (mounted) AppNotice.show(context, '海报已重新获取');
    } on AppFailure catch (error) {
      if (mounted) AppNotice.show(context, error.message);
    } catch (error) {
      if (mounted) AppNotice.show(context, '$error');
    }
  }

  void _dramaActions(Drama drama, {Rect? anchor}) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    anchor: anchor,
    onContinue: () => _openDrama(drama, resume: true),
    onDownload: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _openDrama(drama, download: true)
        : null,
    onSelect: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _selectDrama(drama)
        : null,
    onRefreshCover: () => unawaited(_refreshCover(drama)),
  );

  Widget _catalogTile(
    Drama drama, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final following = widget.store.following(drama.id);
    final canSelect =
        widget.store.canDownload && widget.repository.supportsDownloads;
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => _selectionMode ? _selectDrama(drama) : _openDrama(drama),
      onLongPress: canSelect ? () => _selectDrama(drama) : null,
      onMore: () => _dramaActions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: (anchor) => _dramaActions(drama, anchor: anchor),
      ),
      selected: _selectionMode ? _selectedDramas.containsKey(drama.id) : null,
      badge: following == null
          ? null
          : '${following.status.label}${following.hasUpdates ? ' · ${following.updateLabel}' : ''}',
    );
  }

  void _pauseCatalog() {
    _debounce?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    setState(() {
      _loading = false;
      _loadingMore = false;
    });
  }

  bool get _supportsVipFilter =>
      _group.sources.any((source) => source.id == 'huangdou');
  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;

  List<Drama> get _visible => _viewCache.select(
    _items,
    query: _search.text.trim().toLowerCase(),
    category: _category,
    onlineSearch: _onlineSearch,
    hideVip: _hideVip,
    allowedSources: widget.store.sources.map((source) => source.id).toSet(),
    profileEpoch: widget.store.profileEpoch,
    view: widget.store.catalogView,
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final television = AppLayout.isTelevision(context);
        final desktop = constraints.maxWidth >= 840;
        final navEntries = <(int, IconData, String)>[
          (_tabDiscover, Icons.home_rounded, '主页'),
          (_tabFeed, Icons.play_circle_rounded, '在看'),
          (_tabHistory, Icons.history_rounded, '历史'),
          if (widget.store.canShowLive) (_tabLive, Icons.live_tv_rounded, '直播'),
          if (widget.store.canDownload)
            (_tabDownloads, Icons.download_rounded, '下载'),
        ];
        final tabIndexes = [for (final entry in navEntries) entry.$1];
        final selectedTabIndex = tabIndexes.contains(_tab)
            ? tabIndexes.indexOf(_tab)
            : null;
        final glass =
            widget.store.interfaceStyle == 'glass' && !desktop && !television;
        final bottomBarHidden =
            glass &&
            _tab == _tabDiscover &&
            !_showRecommendations &&
            !_selectionMode &&
            _bottomBarHidden;
        final destinations = [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '主页',
          ),
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline_rounded),
            selectedIcon: Icon(Icons.play_circle_rounded),
            label: '在看',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history_rounded),
            label: '历史',
          ),
          if (widget.store.canShowLive)
            NavigationDestination(
              icon: Icon(Icons.live_tv_outlined),
              selectedIcon: Icon(Icons.live_tv_rounded),
              label: '直播',
            ),
          if (widget.store.canDownload)
            NavigationDestination(
              icon: Icon(Icons.download_outlined),
              selectedIcon: Icon(Icons.download_rounded),
              label: '下载',
            ),
        ];
        final scaffold = Scaffold(
          appBar: AppBar(
            toolbarHeight: television ? 64 : null,
            titleSpacing: 12,
            title: _selectionMode
                ? const Text(
                    '选择短剧',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : _tab == _tabDiscover
                ? KeyedSubtree(
                    key: const ValueKey('source-switch'),
                    child: Semantics(
                      button: true,
                      enabled: _sourceGroups.length > 1,
                      label: '切换站源',
                      child: PressScale(
                        scale: .97,
                        child: Focus(
                          skipTraversal: true,
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent &&
                                (event.logicalKey ==
                                        LogicalKeyboardKey.select ||
                                    event.logicalKey ==
                                        LogicalKeyboardKey.enter ||
                                    event.logicalKey ==
                                        LogicalKeyboardKey.numpadEnter ||
                                    event.logicalKey ==
                                        LogicalKeyboardKey.gameButtonA)) {
                              _openSourceMenu();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: InkWell(
                            key: _sourceMenuKey,
                            borderRadius: BorderRadius.circular(12),
                            overlayColor: WidgetStateProperty.all(
                              Colors.transparent,
                            ),
                            onTap: _sourceGroups.length > 1
                                ? _openSourceMenu
                                : null,
                            child: SizedBox(
                              height: 48,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      _group.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  if (_sourceGroups.length > 1)
                                    const Icon(Icons.expand_more_rounded),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : Text(switch (_tab) {
                    _tabFeed => '在看',
                    _tabFollow => '追剧',
                    _tabHistory => '历史',
                    _tabLive => '直播',
                    _tabDownloads => '下载',
                    _ => appEditionName(widget.store.fullMode),
                  }),
            actions: [
              if (_selectionMode) ...[
                TextButton(
                  key: const ValueKey('clear-catalog-selection'),
                  onPressed: _selectedDramas.isEmpty
                      ? null
                      : () => setState(_selectedDramas.clear),
                  child: const Text('清空'),
                ),
                TextButton(
                  key: const ValueKey('cancel-catalog-selection'),
                  focusNode: _appBarFocus,
                  onPressed: _cancelSelection,
                  child: const Text('取消'),
                ),
              ] else ...[
                if (_tab == _tabFeed)
                  IconButton(
                    key: const ValueKey('feed-refresh'),
                    tooltip: '刷新动态',
                    onPressed: () => RecommendationService.current?.refresh(),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                if (_tab == _tabFollow)
                  IconButton(
                    key: const ValueKey('follow-lan-sync'),
                    tooltip: '追剧同步',
                    onPressed: () => openLanSync(context),
                    icon: const Icon(Icons.sync_rounded),
                  ),
                if (_tab == _tabDiscover) ...[
                  if (!_showRecommendations)
                    IconButton(
                      tooltip: '排序与筛选 · ${widget.store.catalogView.sort.label}',
                      onPressed: _chooseCatalogView,
                      color:
                          widget.store.catalogView.sort != CatalogSort.source ||
                              widget.store.catalogView.release.isNotEmpty
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      icon: const Icon(Icons.sort_rounded),
                    ),
                  IconButton(
                    key: const ValueKey('open-rankings'),
                    tooltip: '榜单',
                    onPressed: widget.store.sources.isEmpty
                        ? null
                        : _openRankings,
                    icon: const Icon(Icons.leaderboard_outlined),
                  ),
                  if (!_showRecommendations &&
                      widget.store.canDownload &&
                      widget.repository.supportsDownloads)
                    IconButton(
                      key: const ValueKey('select-catalog-dramas'),
                      tooltip: '多选下载',
                      onPressed: () => setState(() => _selectionMode = true),
                      icon: const Icon(Icons.checklist_rounded),
                    ),
                  IconButton(
                    key: const ValueKey('toggle-search'),
                    tooltip: _searchVisible ? '收起搜索' : '搜索',
                    icon: Icon(
                      _searchVisible
                          ? Icons.search_off_rounded
                          : Icons.search_rounded,
                    ),
                    onPressed: _toggleSearch,
                  ),
                ],
                if (_tab == _tabDiscover &&
                    !_showRecommendations &&
                    constraints.maxWidth >= 400)
                  RefreshAction(
                    key: const ValueKey('catalog-refresh'),
                    loading:
                        _loading ||
                        _loadingMore ||
                        _categoriesLoading ||
                        _group.sources.any(
                          (source) => _updater.busy(source.id),
                        ),
                    tooltip: '更新剧库',
                    onPressed: widget.store.sources.isEmpty
                        ? null
                        : _refreshCatalog,
                  ),
                IconButton(
                  key: _moreMenuKey,
                  tooltip: '更多',
                  onPressed: () => _openMoreMenu(constraints.maxWidth),
                  icon: const Icon(Icons.more_vert_rounded),
                ),
              ],
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: !glass,
            child: Row(
              children: [
                if (television) ...[
                  SizedBox(
                    width: 176,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                      child: RemoteList(
                        key: _navKey,
                        itemKeys: [
                          for (final entry in navEntries) '${entry.$1}',
                        ],
                        itemExtent: 60,
                        spacing: 14,
                        padding: EdgeInsets.zero,
                        autofocus: true,
                        onExitRight: _tab == _tabDiscover
                            ? () => _gridKey.currentState?.focusCurrent()
                            : null,
                        itemBuilder: (_, index, node, onFocus) {
                          final entry = navEntries[index];
                          return RemoteButton(
                            key: ValueKey('tv-nav-${entry.$1}'),
                            label: entry.$3,
                            icon: entry.$2,
                            selected: _tab == entry.$1,
                            focusNode: node,
                            onFocus: onFocus,
                            onPressed: () => _changeTab(entry.$1),
                          );
                        },
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ] else if (desktop) ...[
                  NavigationRail(
                    selectedIndex: selectedTabIndex,
                    onDestinationSelected: (index) =>
                        _changeTab(tabIndexes[index]),
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -.8,
                    destinations: [
                      NavigationRailDestination(
                        icon: Icon(Icons.home_outlined),
                        selectedIcon: Icon(Icons.home_rounded),
                        label: Text('主页'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.play_circle_outline_rounded),
                        selectedIcon: Icon(Icons.play_circle_rounded),
                        label: Text('在看'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.history_outlined),
                        selectedIcon: Icon(Icons.history_rounded),
                        label: Text('历史'),
                      ),
                      if (widget.store.canShowLive)
                        NavigationRailDestination(
                          icon: Icon(Icons.live_tv_outlined),
                          selectedIcon: Icon(Icons.live_tv_rounded),
                          label: Text('直播'),
                        ),
                      if (widget.store.canDownload)
                        NavigationRailDestination(
                          icon: Icon(Icons.download_outlined),
                          selectedIcon: Icon(Icons.download_rounded),
                          label: Text('下载'),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                ],
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: KeyedSubtree(
                      key: ValueKey(
                        'home-tab-$_tab${_showRecommendations ? '-rec' : ''}',
                      ),
                      child: _tab == _tabDiscover
                          ? widget.store.sources.isEmpty
                                ? const StatusPanel(
                                    title: '暂无可用站源',
                                    message: '请联系管理员为当前用户开放站源。',
                                  )
                                : _catalog(
                                    selectionInBody: desktop || television,
                                  )
                          : _tab == _tabFeed
                          ? FeedsScreen(
                              key: const ValueKey('feed-tab'),
                              repository: widget.repository,
                              store: widget.store,
                              onExitLeft: television
                                  ? () => _navKey.currentState?.focusCurrent()
                                  : null,
                            )
                          : _tab == _tabLive
                          ? LiveScreen(
                              key: const ValueKey('live-tab'),
                              repository: _liveRepository,
                              store: _liveStore,
                              greenMode: allSourcesEnabled
                                  ? false
                                  : widget.store.greenMode,
                              onExitLeft: television
                                  ? () => _navKey.currentState?.focusCurrent()
                                  : null,
                            )
                          : _tab == _tabDownloads
                          ? DownloadsScreen(
                              repository: widget.repository,
                              store: widget.store,
                              embedded: true,
                            )
                          : SavedLibrary(
                              key: ValueKey('saved-tab-$_tab'),
                              repository: widget.repository,
                              store: widget.store,
                              history: _tab == _tabHistory,
                              historyToggle: false,
                              remoteAutofocus: television,
                              onExitLeft: television
                                  ? () => _navKey.currentState?.focusCurrent()
                                  : null,
                              onOpen: _openDrama,
                              onContinue: (drama) =>
                                  _openDrama(drama, resume: true),
                              onDownload:
                                  widget.repository.supportsDownloads &&
                                      widget.store.canDownload
                                  ? (drama) => _openDrama(drama, download: true)
                                  : null,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          extendBody: glass,
          bottomNavigationBar: desktop || television
              ? null
              : _selectionMode
              ? _selectionBar(glass: glass)
              : glass
              ? AnimatedSlide(
                  offset: bottomBarHidden ? const Offset(0, 1.4) : Offset.zero,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: bottomBarHidden ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: bottomBarHidden,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            GlassBottomNavigation.sideMargin,
                            0,
                            GlassBottomNavigation.sideMargin,
                            GlassBottomNavigation.bottomMargin,
                          ),
                          child: GlassBottomNavigation(
                            selectedIndex: selectedTabIndex,
                            onDestinationSelected: (index) =>
                                _changeTab(tabIndexes[index]),
                            destinations: destinations,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : AppBottomNavigation(
                  selectedIndex: selectedTabIndex,
                  onDestinationSelected: (index) =>
                      _changeTab(tabIndexes[index]),
                  destinations: destinations,
                ),
        );
        if (!television) {
          Widget content = scaffold;
          if (glass && _tab == _tabDiscover && !_showRecommendations) {
            content = Stack(
              children: [
                Positioned.fill(child: scaffold),
                if (!_selectionMode)
                  AnimatedPositioned(
                    right: 20,
                    bottom:
                        (bottomBarHidden
                            ? GlassBottomNavigation.bottomMargin
                            : GlassBottomNavigation.contentInset) +
                        MediaQuery.paddingOf(context).bottom,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: GlassBackToTopButton(
                      visible: _backToTopVisible,
                      onPressed: _scrollToTop,
                    ),
                  ),
              ],
            );
          }
          return PopScope(
            canPop: !_selectionMode,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) _televisionBack();
            },
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    Navigator.of(context).maybePop(),
                const SingleActivator(LogicalKeyboardKey.goBack): () =>
                    Navigator.of(context).maybePop(),
              },
              child: content,
            ),
          );
        }
        return PopScope(
          canPop:
              !_selectionMode && _tab == _tabDiscover && _search.text.isEmpty,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _televisionBack();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).maybePop(),
              const SingleActivator(LogicalKeyboardKey.goBack): () =>
                  Navigator.of(context).maybePop(),
            },
            child: scaffold,
          ),
        );
      },
    ),
  );

  Widget _catalog({required bool selectionInBody}) {
    final items = _visible;
    final television = AppLayout.isTelevision(context);
    return Column(
      children: [
        if (_searchVisible && !television)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: SearchInput(
              key: ValueKey('search-${_group.id}'),
              controller: _search,
              autofocus: true,
              hint: _searchHint,
              suggestions: _searchSuggestions
                  ? widget.repository.suggestions
                  : null,
              onChanged: _searchChanged,
              onCancel: () => unawaited(widget.repository.cancelSuggestions()),
              onSearch: _submitSearch,
            ),
          ),
        if (_searchVisible &&
            _search.text.trim().isEmpty &&
            widget.store.recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final query in widget.store.recentSearches)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: const Icon(
                                Icons.history_rounded,
                                size: 16,
                              ),
                              label: Text(query),
                              onPressed: () => _submitSearch(query),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '清空最近搜索',
                  onPressed: () =>
                      saveUserChange(context, widget.store.clearRecentSearches),
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ],
            ),
          ),
        CatalogFilters(
          key: ValueKey('filters-${_group.id}'),
          categories: _displayCategories,
          category: _displayCategory,
          error: _categoriesError,
          remoteKey: _filtersKey,
          onExitUp: television && _selectionMode
              ? () => _appBarFocus.requestFocus()
              : null,
          onExitDown: television
              ? () => _gridKey.currentState?.focusCurrent()
              : null,
          onCategory: _changeCategory,
          onRetry: () => _loadCategories(force: true),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_supportsVipFilter)
                IconButton(
                  tooltip: widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
                  onPressed: () => saveUserChange(
                    context,
                    () => widget.store.setHideVip(!widget.store.hideVip),
                  ),
                  icon: VipIcon(hidden: widget.store.hideVip),
                ),
            ],
          ),
        ),
        if (_showRecommendations)
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: RecommendationsScreen(
                repository: widget.repository,
                store: widget.store,
                embedded: true,
                gridKey: _gridKey,
                onExitLeft: television
                    ? () => _navKey.currentState?.focusCurrent()
                    : null,
              ),
            ),
          )
        else ...[
          if (_loading && _items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: _loading && _items.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 18),
                          Text('正在加载剧集'),
                        ],
                      ),
                    )
                  : _items.isEmpty && _error != null
                  ? StatusPanel(
                      title: '暂时无法加载',
                      message: _error!,
                      onRetry: () => _load(force: true),
                      secondaryAction:
                          widget.repository.supportsSourceManagement
                          ? TextButton(
                              onPressed: _manageSources,
                              child: const Text('站源诊断'),
                            )
                          : null,
                      icon: Icons.wifi_off_rounded,
                    )
                  : items.isEmpty
                  ? StatusPanel(
                      title: '没有找到匹配的短剧',
                      message: _hideVip
                          ? '可以换个搜索词，或显示 VIP 内容。'
                          : widget.store.sources.length > 1
                          ? '可以换个搜索词或切换站源。'
                          : '可以换个搜索词，或刷新后重试。',
                      onRetry:
                          _hasMore &&
                              !_loadingMore &&
                              (!_onlineSearch ||
                                  _search.text.isEmpty ||
                                  _group.sources.any(
                                    (source) => source.pagedSearch,
                                  ))
                          ? () => _load(more: true)
                          : null,
                      action: '加载更多',
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        if (television) {
                          return _televisionGrid(
                            items,
                            constraints.maxWidth,
                            controller: _scroll,
                            footer: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                              child: Center(
                                child: _loadingMore
                                    ? const CircularProgressIndicator()
                                    : _hasMore
                                    ? RemoteButton(
                                        label: '加载更多',
                                        icon: Icons.expand_more,
                                        onPressed: () => _load(more: true),
                                      )
                                    : const Text('已经看到这里的全部剧集'),
                              ),
                            ),
                          );
                        }
                        final padding = constraints.maxWidth < 600
                            ? 16.0
                            : 24.0;
                        return RefreshIndicator(
                          onRefresh: _refreshCatalog,
                          child: CustomScrollView(
                            controller: _scroll,
                            scrollCacheExtent: ScrollCacheExtent.viewport(1),
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  padding,
                                  0,
                                  padding,
                                  16,
                                ),
                                sliver: SliverGrid(
                                  gridDelegate: dramaGridDelegate(
                                    context,
                                    constraints.maxWidth - 2 * padding,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (_, index) => _catalogTile(items[index]),
                                    childCount: items.length,
                                  ),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  child: Center(
                                    child: _loadingMore
                                        ? const CircularProgressIndicator()
                                        : _hasMore
                                        ? OutlinedButton.icon(
                                            onPressed: () => _load(more: true),
                                            icon: const Icon(
                                              Icons.expand_more_rounded,
                                            ),
                                            label: const Text('加载更多'),
                                          )
                                        : Text(
                                            '已经看到这里的全部剧集',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
          if (_selectionMode && selectionInBody)
            _selectionBar(safeBottom: false),
        ],
      ],
    );
  }

  Widget _selectionBar({bool safeBottom = true, bool glass = false}) {
    final theme = Theme.of(context);
    final count = _selectedDramas.length;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final summary = Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 0 ? '点选要下载的短剧' : '已选 $count 部',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  count == 0
                      ? '最多 ${BatchDownloads.maxDramas} 部'
                      : '下一步选择分集和画质',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
          final next = FilledButton(
            key: const ValueKey('download-selected-dramas'),
            focusNode: _selectionFocus,
            onPressed: count == 0 ? null : _downloadSelected,
            style: FilledButton.styleFrom(
              minimumSize: const Size(96, 48),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            child: const Text('下一步'),
          );
          if (constraints.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(14) > 21) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: 12), next],
            );
          }
          return Row(
            children: [
              Expanded(child: summary),
              const SizedBox(width: 16),
              next,
            ],
          );
        },
      ),
    );
    if (glass) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            GlassBottomNavigation.sideMargin,
            0,
            GlassBottomNavigation.sideMargin,
            GlassBottomNavigation.bottomMargin,
          ),
          child: GlassPanel(child: content),
        ),
      );
    }
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(top: false, bottom: safeBottom, child: content),
      ),
    );
  }

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    ScrollController? controller,
    Widget? footer,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: _gridKey,
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      onExitUp: () => _filtersKey.currentState?.focusCurrent(),
      onExitLeft: () => _navKey.currentState?.focusCurrent(),
      onExitDown: _selectionMode ? () => _selectionFocus.requestFocus() : null,
      itemBuilder: (_, index, node, onFocus) =>
          _catalogTile(items[index], focusNode: node, onFocus: onFocus),
    );
  }
}

class _AboutDialog extends StatefulWidget {
  const _AboutDialog({required this.store, required this.repository});
  final LocalStore store;
  final AppRepository repository;
  @override
  State<_AboutDialog> createState() => _AboutDialogState();
}

class _AboutDialogState extends State<_AboutDialog> {
  static const _required = 5;
  int _taps = 0;
  final _liveCode = TextEditingController();
  String? _liveCodeError;

  @override
  void dispose() {
    _liveCode.dispose();
    super.dispose();
  }

  Future<void> _tapVersion() async {
    _taps += 1;
    if (_taps < _required) return;
    _taps = 0;
    final navigator = Navigator.of(context);
    await widget.store.setFullMode(!widget.store.fullMode);
    if (mounted) navigator.pop();
  }

  Future<void> _activateLive() async {
    if (_liveCode.text.trim() != liveActivationCode) {
      setState(() => _liveCodeError = '激活码不正确');
      return;
    }
    try {
      await widget.store.setLiveActivated(true);
      if (mounted) setState(() => _liveCodeError = null);
    } catch (error) {
      if (mounted) setState(() => _liveCodeError = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GlassPanel(
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                child: Icon(
                  Icons.play_circle_filled_rounded,
                  size: 48,
                  color: Color(0xFFFF765F),
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: Text(
                  appEditionName(widget.store.fullMode),
                  style: theme.textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 8),
              if (allSourcesEnabled)
                TextButton(
                  key: const ValueKey('about-version'),
                  autofocus: AppLayout.isTelevision(context),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _tapVersion,
                  child: Text(
                    AppLayout.versionOf(context),
                    style: theme.textTheme.titleSmall,
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    AppLayout.versionOf(context),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              const SizedBox(height: 8),
              const Text('独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。'),
              const SizedBox(height: 16),
              if (widget.store.liveActivated)
                const Text('直播已激活')
              else ...[
                FormTextField(
                  key: const ValueKey('about-live-code'),
                  controller: _liveCode,
                  decoration: InputDecoration(
                    labelText: '直播激活码',
                    errorText: _liveCodeError,
                  ),
                  onSubmitted: (_) => _activateLive(),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: OutlinedButton(
                    key: const ValueKey('about-live-activate'),
                    onPressed: _activateLive,
                    child: const Text('激活直播'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  final navigator = Navigator.of(context);
                  navigator.pop();
                  navigator.push(
                    MaterialPageRoute<void>(
                      builder: (_) => AppUpdateScreen(
                        store: widget.store,
                        repository: widget.repository,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.system_update_rounded),
                label: const Text('检查更新'),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => showLicensePage(
                      context: context,
                      applicationName: appEditionName(widget.store.fullMode),
                      applicationVersion: AppLayout.versionOf(context),
                    ),
                    child: const Text('开源许可'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
