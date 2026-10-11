import 'package:flutter/foundation.dart';

@immutable
class CatalogFolder {
  /// POSIX-relative path from catalog root; "" represents the root itself.
  final String path;

  /// Number of photos directly or transitively under this folder.
  final int photoCount;

  /// Drive file ID of the photo used as this folder's cover thumbnail.
  final String? coverThumbPath;

  /// Extra photo ids rendered as a "stack" peeking out behind the cover, so a
  /// folder tile visibly reads as a folder of designs rather than one image.
  final List<String> previewThumbPaths;

  const CatalogFolder({
    required this.path,
    required this.photoCount,
    this.coverThumbPath,
    this.previewThumbPaths = const [],
  });

  String get displayName {
    if (path.isEmpty) return 'Catalog';
    final i = path.lastIndexOf('/');
    return i == -1 ? path : path.substring(i + 1);
  }

  int get depth => path.isEmpty ? 0 : path.split('/').length;
}
