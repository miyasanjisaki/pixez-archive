import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pixez/models/bookmark_library.dart';
import 'package:pixez/network/bookmark_library_client.dart';

enum BookmarkSyncState { idle, syncing, failed }

/// UI state for the bookmark search page. Shared by Material and Fluent.
class BookmarkSearchController extends ChangeNotifier {
  final int userId;
  final BookmarkLibrary library;

  BookmarkSearchController({required this.userId, BookmarkLibrary? library})
    : library = library ?? bookmarkLibrary;

  BookmarkLibraryQuery _query = const BookmarkLibraryQuery();
  BookmarkLibraryQuery get query => _query;

  BookmarkLibraryStats stats = const BookmarkLibraryStats();
  BookmarkLibrarySearchResult? result;

  /// Bumped on every new result so list widgets know to rebuild their source.
  int resultGeneration = 0;

  BookmarkSyncState syncState = BookmarkSyncState.idle;
  BookmarkSyncProgress? syncProgress;
  String? syncError;
  BookmarkSyncCancelToken? _syncToken;
  Timer? _debounce;
  int _searchSerial = 0;
  bool _disposed = false;

  bool get isSyncing => syncState == BookmarkSyncState.syncing;

  Future<void> start() async {
    await _refreshStats();
    await search();
    // An incremental sync is cheap (usually one request); the first sync
    // walks every page but results appear as pages arrive.
    unawaited(sync());
  }

  void updateQuery(BookmarkLibraryQuery query, {bool debounce = false}) {
    _query = query;
    _debounce?.cancel();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 300), search);
    } else {
      unawaited(search());
    }
    _notify();
  }

  Future<void> search() async {
    final serial = ++_searchSerial;
    final found = await library.search(userId, _query);
    if (_disposed || serial != _searchSerial) return;
    result = found;
    resultGeneration++;
    _notify();
  }

  Future<void> sync({bool full = false}) async {
    if (isSyncing) return;
    final token = BookmarkSyncCancelToken();
    _syncToken = token;
    syncState = BookmarkSyncState.syncing;
    syncError = null;
    syncProgress = null;
    _notify();
    final hadResults = stats.total > 0;
    var pagesSinceRefresh = 0;
    final outcome = await library.sync(
      userId,
      full: full,
      cancelToken: token,
      onProgress: (progress) {
        syncProgress = progress;
        _notify();
        // While building the library for the first time, show works as
        // they arrive instead of an empty page for minutes.
        if (!hadResults && ++pagesSinceRefresh >= 5) {
          pagesSinceRefresh = 0;
          unawaited(_refreshStats().then((_) => search()));
        }
      },
    );
    if (_disposed) return;
    _syncToken = null;
    syncState = outcome.error == null
        ? BookmarkSyncState.idle
        : BookmarkSyncState.failed;
    syncError = outcome.error == null ? null : _describe(outcome.error!);
    await _refreshStats();
    if (outcome.added > 0 ||
        outcome.removed > 0 ||
        outcome.updated > 0 ||
        !hadResults) {
      await search();
    }
    _notify();
  }

  void cancelSync() => _syncToken?.cancel();

  Future<void> clearLibrary() async {
    cancelSync();
    await library.clear(userId);
    await _refreshStats();
    await search();
  }

  Future<void> _refreshStats() async {
    final value = await library.stats(userId);
    final facetValue = await library.facets(userId);
    if (_disposed) return;
    stats = value;
    facets = facetValue;
    _notify();
  }

  /// Tag/artist counts for the quick filters, refreshed with [stats].
  BookmarkLibraryFacets facets = const BookmarkLibraryFacets();

  String _describe(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 429) return 'Pixiv rate limit (429)';
      if (status == 401 || status == 403) return 'Login expired ($status)';
      if (status != null) return 'HTTP $status';
      return 'Network error';
    }
    if (error is FormatException) return error.message;
    return 'Sync failed';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _syncToken?.cancel();
    super.dispose();
  }
}
