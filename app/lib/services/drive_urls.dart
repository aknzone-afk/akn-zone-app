/// Public Google Drive URL builders. No auth required for files in
/// "Anyone with the link can view" folders.
class DriveUrls {
  /// Thumbnail of arbitrary width. Drive returns a JPG, follows redirects to
  /// the actual blob. Safe for `cached_network_image`.
  static String thumbnail(String fileId, {int width = 400}) {
    return 'https://drive.google.com/thumbnail?id=$fileId&sz=w$width';
  }

  /// The file's current content. A HEAD request here returns its version ETag
  /// without downloading the image.
  static String content(String fileId) {
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
