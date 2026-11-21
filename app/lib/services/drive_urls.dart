/// Public Google Drive URL builders. No auth required for files in
/// "Anyone with the link can view" folders.
class DriveUrls {
  /// Owner 21-Nov-2026: a design that is NOT in the app has no Drive file —
  /// its photo comes from the shop's full photo set (the one the Rate Bolo
  /// page shows). Such a photo's id is `rb-<KEY>_<hash>`; every address built
  /// from an id goes through this class, so the rest of the app needs no
  /// special case. One size only (720 px).
  static const oldPrefix = 'rb-';
  static const oldBase = 'https://aknzone-afk.github.io/rate-bolo/';
  static bool isOld(String id) => id.startsWith(oldPrefix);
  static String oldUrl(String id) => '${oldBase}p/${id.substring(oldPrefix.length)}.jpg';

  /// Thumbnail of arbitrary width. Drive returns a JPG, follows redirects to
  /// the actual blob. Safe for `cached_network_image`.
  static String thumbnail(String fileId, {int width = 400}) {
    if (isOld(fileId)) return oldUrl(fileId);
    return 'https://drive.google.com/thumbnail?id=$fileId&sz=w$width';
  }

  /// The file's current content. A HEAD request here returns its version ETag
  /// without downloading the image.
  static String content(String fileId) {
    if (isOld(fileId)) return oldUrl(fileId);
    return 'https://lh3.googleusercontent.com/d/$fileId';
  }

  /// User-facing folder URL (only for "Open in Drive" affordances).
  static String folder(String folderId) {
    return 'https://drive.google.com/drive/folders/$folderId';
  }

  /// Embedded folder view — the HTML endpoint we scrape for listings.
  /// Works anonymously for public folders.
  static String embeddedFolder(String folderId) {
    return 'https://drive.google.com/embeddedfolderview?id=$folderId#list';
  }
}
