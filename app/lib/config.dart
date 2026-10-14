/// App-wide configuration. **Edit kDriveFolderId before building.**
library;

/// The Google Drive folder ID that is the root of the catalog.
///
/// Get it from the share URL: `https://drive.google.com/drive/folders/<THIS_PART>?usp=sharing`
/// The folder MUST be shared as "Anyone with the link can view".
const String kDriveFolderId = '1AG83ju3RkiUd16Y6PP8Lo2VyXI25Zfnx';

/// Re-scrape Drive after this duration; otherwise serve from SQLite cache.
const Duration kCatalogRefreshInterval = Duration(minutes: 10);

/// Grid thumbnail width (`sz=wN`), also the image prices are read from.
/// MUST stay above 512: Drive serves sizes ≤512 from a preview made at first
/// upload, which it never refreshes when a photo is replaced — so a replaced
/// photo showed its old printed price there. Larger sizes come from the
/// current file.
const int kThumbnailWidth = 600;

/// How many photos to download + OCR in parallel. Downloads dominate, and a
/// dozen keeps the network busy without piling up decoded 600px images while
/// ML Kit (one image at a time) catches up.
// 12-Oct-2026: 12 parallel ML Kit reads ran the iPhone out of memory on the
// first load (crash at 55%) — 3 at a time is safe.
const int kOcrConcurrency = 5;

/// How many pending photos to fetch from SQLite per batch.
const int kOcrBatchSize = 128;

/// Detail-view image size for the photo viewer.
const int kDetailImageWidth = 2000;

/// App branding.
const String kAppTitle = 'AKN ZONE';
const String kBrandSubtitle = 'SURAT SAREE MANUFACTURER';

/// Default WhatsApp number for the "Contact us" CTA (international format,
/// no leading +). Leave empty to hide the contact button.
const String kContactWhatsAppNumber = ''; // e.g. '919876543210'

/// Customer care (owner, 11-Oct-2026) — the app's Help button.
const String kCustomerCareNumber = '917016638059';
const String kCustomerCareDisplay = '70166 38059';

/// Maximum number of photos a customer can select for one WhatsApp share.
const int kMaxShareBatch = 30;

/// Markup tool defaults — bright green pen + a bolder stroke, matching the
/// checkmarks used to tick designs for ordering.
const double kMarkupDefaultStrokeWidth = 12.0;
const List<int> kMarkupPaletteARGB = [
  0xFF3DE04B, // bright green (DEFAULT — order checkmark)
  0xFF1E1E1E, // near-black
  0xFFFFFFFF, // white
  0xFF1565C0, // blue
  0xFFE53935, // red
  0xFFFDD835, // yellow
];

/// Price-parsing regexes, ordered by preference.
const List<String> kPriceRegexes = [
  r'(?:RS|Rs|₹)\.?\s*(\d{2,6})(?:[/.]?[-_])?',
  r'(\d{3,6})\s*/-',
];

/// Design-number regex applied to filenames. Captures the first all-digits run
/// (optionally prefixed by letters).
const String kDesignNumberRegex = r'([A-Za-z]*\d{3,})';

/// Pick the smallest price when multiple appear (wholesale heuristic).
const bool kPickSmallestPrice = true;

/// High-level browse categories for the Filter sheet. A design's category is
/// decided by its top-level Drive folder name — adjust the keyword checks in
/// [fabricCategoryOf] if your folder names change.
/// Each category maps to specific top-level Drive folder(s) by exact
/// (normalised) name. "Dyed Work" is the catch-all for everything else.
/// Add folder names to a category's `folders` list to include more.
const List<({String key, String label, List<String> folders})>
    kFabricCategories = [
  (key: 'printed', label: 'Printed', folders: ['PRINTED SAREES']),
  (key: 'banarasi', label: 'Banarasi', folders: ['BANARASI (WEAVING)']),
  (key: 'bandhani', label: 'Bandhani & Lehariya', folders: ['BANDHANI']),
  (key: 'dyed', label: 'Dyed Work', folders: <String>[]), // catch-all
];

String _normFolder(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Maps a top-level folder name to a category key. "Printed" / "Banarasi"
/// match their specific folder(s) by exact (normalised) name; everything
/// else falls into "Dyed Work".
String fabricCategoryOf(String topFolder) {
  final t = _normFolder(topFolder);
  for (final cat in kFabricCategories) {
    for (final f in cat.folders) {
      if (t == _normFolder(f)) return cat.key;
    }
  }
  return 'dyed';
}

/// ---- Customer access control (login gate) ----
/// When true, the app requires customers to enter their registered mobile
/// number before accessing the catalog. The number is checked against the
/// Google Sheet customer list via CSV endpoint.
const bool kAccessControlEnabled = false;

/// Shop website. Links like `$kWebsiteBase/d/1444` open that design in the app.
const String kWebsiteBase = 'https://bbsynthetics.in';

/// Where ORDER NOW reads the Telegram bot token + group id (kept on the
/// website, not in the app, so the bot can be replaced without an app update).
// 3.0.0: own copy — the old file is switched off for old apps on release day.
/// Owner 14-Oct: the app's data files moved to GitHub Pages (Netlify's free
/// deploy credits ran out). bbsynthetics.in stays for links / website.
const String kDataBase = 'https://aknzone-afk.github.io/akn-zone-data';

/// Store review: the privacy policy (GitHub Pages — Netlify deploys paused).
const String kPrivacyUrl = '$kDataBase/privacy.html';

const String kOrderConfigUrl = '$kDataBase/app/order-config-v3.json';
/// Minimum build per platform (min_build_ios / min_build_android) → "Update now".
const String kAppConfigUrl = '$kDataBase/app/app-config.json';

/// Minimum order value (owner, same rule as AKN Chat): price × pieces summed
/// over the order. Below this the order cannot be sent — the customer is asked
/// to select more. If some designs have no price the value can't be judged, so
/// the order goes through and the shop checks it.
const int kMinOrderValue = 30000;
