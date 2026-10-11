import 'local_cache.dart';

/// Thin wrapper around LocalCache's favorites table. Kept separate so the
/// Riverpod provider doesn't pull in SQLite types.
class FavoritesService {
  final LocalCache _cache;
  FavoritesService(this._cache);

  Future<Set<String>> load() => _cache.allFavoriteIds();
  Future<void> setStarred(String photoId, bool starred) =>
      _cache.setFavorite(photoId, starred);
  Future<void> clear() => _cache.clearFavorites();
}
