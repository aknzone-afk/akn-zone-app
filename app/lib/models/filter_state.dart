import 'package:flutter/foundation.dart';

/// Immutable filter state, copied with copyWith on each change.
@immutable
class FilterState {
  final String
      query; // free text — matches fabric name + filename + design number
  final RangeValues
      priceRange; // null-equivalent: defaults to (0, double.infinity)
  final Set<String> folders; // empty = all folders
  final bool favoritesOnly;
  final SortBy sortBy;
  final bool sortAsc;
  final Set<String> categories; // empty = all categories

  const FilterState({
    this.query = '',
    this.priceRange = const RangeValues(0, double.infinity),
    this.folders = const <String>{},
    this.favoritesOnly = false,
    this.sortBy = SortBy.shuffle,
    this.sortAsc = true,
    this.categories = const <String>{},
  });

  bool get isActive =>
      query.isNotEmpty ||
      priceRange.min > 0 ||
      priceRange.max.isFinite ||
      folders.isNotEmpty ||
      favoritesOnly ||
      categories.isNotEmpty;

  FilterState copyWith({
    String? query,
    RangeValues? priceRange,
    Set<String>? folders,
    bool? favoritesOnly,
    SortBy? sortBy,
    bool? sortAsc,
    Set<String>? categories,
  }) {
    return FilterState(
      query: query ?? this.query,
      priceRange: priceRange ?? this.priceRange,
      folders: folders ?? this.folders,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      sortBy: sortBy ?? this.sortBy,
      sortAsc: sortAsc ?? this.sortAsc,
      categories: categories ?? this.categories,
    );
  }

  FilterState clear() => const FilterState();
}

enum SortBy {
  /// Fresh random order each time a folder is opened (the default).
  shuffle,
  folderThenName,
  priceAsc,
  priceDesc,
  modifiedDesc,
  designNumber,
  fabricName,
}

/// Replacement for Flutter's `RangeValues` that allows `double.infinity` for "no upper bound".
@immutable
class RangeValues {
  final double min;
  final double max;
  const RangeValues(this.min, this.max);

  RangeValues copyWith({double? min, double? max}) =>
      RangeValues(min ?? this.min, max ?? this.max);

  @override
  bool operator ==(Object other) =>
      other is RangeValues && other.min == min && other.max == max;
  @override
  int get hashCode => Object.hash(min, max);
}
