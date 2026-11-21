/// An order placed from the cart. Saved on the device (order history + the
/// send queue) and delivered to the shop's Telegram group by [OrderService].
library;

/// Owner 21-Nov-2026: a design that is NOT in the app any more (design over /
/// an old design), typed by the customer on the order screen — number,
/// pieces and any choice of colours. It has no photo and no price.
class OldDesign {
  final String design;
  final int qty;
  final String colours;
  const OldDesign({required this.design, required this.qty, this.colours = ''});

  Map<String, dynamic> toJson() => {'d': design, 'q': qty, if (colours.isNotEmpty) 'c': colours};

  factory OldDesign.fromJson(Map<String, dynamic> j) => OldDesign(
      design: '${j['d'] ?? ''}', qty: (j['q'] as num?)?.toInt() ?? 0, colours: '${j['c'] ?? ''}');
}

class OrderItem {
  final String photoId;
  final String? designNumber;
  final String folder;
  final int? price;
  int qty;

  /// "2 SET + 3 pcs" when the customer used tap-to-select.
  final String? pick;

  OrderItem({
    required this.photoId,
    required this.designNumber,
    required this.folder,
    required this.price,
    this.qty = 1,
    this.pick,
  });

  Map<String, dynamic> toJson() => {
        'id': photoId,
        'd': designNumber,
        'f': folder,
        'p': price,
        'q': qty,
        if (pick != null) 'k': pick,
      };

  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        photoId: j['id'] as String,
        designNumber: j['d'] as String?,
        folder: (j['f'] ?? '') as String,
        price: j['p'] as int?,
        qty: (j['q'] ?? 1) as int,
        pick: j['k'] as String?,
      );
}

/// The customer's billing / delivery details. Remembered on the device so a
/// repeat customer only checks and taps Send.
class CustomerDetails {
  String country;
  String billName;
  String address;
  String bookingPlace;
  String pincode;
  String mobile;
  String transport;
  String taxId; // GST / PAN / Aadhaar — optional

  /// 'old' = found in Tally by mobile, 'new' = filled the full form.
  String kind;

  CustomerDetails({
    this.kind = 'new',
    this.country = 'India',
    this.billName = '',
    this.address = '',
    this.bookingPlace = '',
    this.pincode = '',
    this.mobile = '',
    this.transport = '',
    this.taxId = '',
  });

  bool get isIndia => country == 'India';

  Map<String, dynamic> toJson() => {
        'country': country,
        'billName': billName,
        'address': address,
        'bookingPlace': bookingPlace,
        'pincode': pincode,
        'mobile': mobile,
        'transport': transport,
        'taxId': taxId,
        'kind': kind,
      };

  factory CustomerDetails.fromJson(Map<String, dynamic> j) => CustomerDetails(
        country: (j['country'] ?? 'India') as String,
        billName: (j['billName'] ?? '') as String,
        address: (j['address'] ?? '') as String,
        bookingPlace: (j['bookingPlace'] ?? '') as String,
        pincode: (j['pincode'] ?? '') as String,
        mobile: (j['mobile'] ?? '') as String,
        transport: (j['transport'] ?? '') as String,
        taxId: (j['taxId'] ?? '') as String,
        kind: (j['kind'] ?? 'new') as String,
      );
}

enum OrderStatus { pending, sent }

class Order {
  final String number; // e.g. AKN-1011-1215-K7Q
  final DateTime createdAt;
  final List<OrderItem> items;
  final CustomerDetails customer;
  final String note;

  /// Designs typed by hand that are not in the app (see [OldDesign]).
  final List<OldDesign> oldDesigns;

  /// Phone-lock warning for the shop ("NEW PHONE…", "2nd number…").
  final String? lockNote;

  /// Set when this order is an ADD-ON to an earlier order's parcel (placed
  /// within its 2-day window, no minimum).
  final String? addOnTo;

  /// Shop-wide serial "ORDER NO. 1, 2, 3…" (cloud counter), fixed once given.
  int? serial;
  OrderStatus status;

  /// Delivery progress, so a retry after a dropped connection never posts the
  /// same photos to the group twice.
  int photoChunksSent;
  bool detailsSent;
  bool dotsSent;

  /// The separate "ORDER NO. N" message (owner 11-Oct) reached the group.
  bool noSent;

  /// NEW customer: held on the phone until the 10% advance is verified
  /// (owner 12-Oct); then sent with [advancePaid].
  bool awaitingAdvance;
  int? advancePaid;
  String? advanceUtr;

  /// Telegram chat + ids of this order's messages (details; album photos,
  /// "ORDER NO. N", the dots) and whether the cloud has them. A staff reply
  /// to ANY of them reaches the customer's chat; registration is retried
  /// until it succeeds (tester 13-Oct: one lost call = no status, no bill).
  String? tgChat;
  int? tgMsgId;
  List<int> tgExtraIds;
  bool registered;
  String? lastError;

  Order({
    required this.number,
    required this.createdAt,
    required this.items,
    required this.customer,
    this.note = '',
    List<OldDesign>? oldDesigns,
    this.lockNote,
    this.addOnTo,
    this.serial,
    this.status = OrderStatus.pending,
    this.photoChunksSent = 0,
    this.detailsSent = false,
    this.dotsSent = false,
    this.noSent = false,
    this.awaitingAdvance = false,
    this.advancePaid,
    this.advanceUtr,
    this.tgChat,
    this.tgMsgId,
    List<int>? tgExtraIds,
    this.registered = false,
    this.lastError,
  })  : tgExtraIds = tgExtraIds ?? [],
        oldDesigns = oldDesigns ?? const [];

  int get totalPcs => items.fold(0, (s, i) => s + i.qty);

  /// Approximate value from the catalog prices; null when no design has one.
  int? get approxTotal {
    var any = false;
    var sum = 0;
    for (final i in items) {
      if (i.price != null) {
        any = true;
        sum += i.price! * i.qty;
      }
    }
    return any ? sum : null;
  }

  Map<String, dynamic> toJson() => {
        'number': number,
        'createdAt': createdAt.toIso8601String(),
        'items': items.map((e) => e.toJson()).toList(),
        'customer': customer.toJson(),
        'note': note,
        if (oldDesigns.isNotEmpty) 'old': oldDesigns.map((e) => e.toJson()).toList(),
        if (lockNote != null) 'lock': lockNote,
        if (addOnTo != null) 'addOnTo': addOnTo,
        if (serial != null) 'serial': serial,
        'status': status.name,
        'chunks': photoChunksSent,
        'details': detailsSent,
        'dots': dotsSent,
        'no': noSent,
        if (awaitingAdvance) 'hold': true,
        if (advancePaid != null) 'adv': advancePaid,
        if (advanceUtr != null) 'advUtr': advanceUtr,
        if (tgChat != null) 'chat': tgChat,
        if (tgMsgId != null) 'msgId': tgMsgId,
        if (tgExtraIds.isNotEmpty) 'extra': tgExtraIds,
        'reg': registered,
        'err': lastError,
      };

  factory Order.fromJson(Map<String, dynamic> j) => Order(
        number: j['number'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        items: (j['items'] as List)
            .map((e) => OrderItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        customer:
            CustomerDetails.fromJson(Map<String, dynamic>.from(j['customer'])),
        note: (j['note'] ?? '') as String,
        oldDesigns: [
          for (final e in (j['old'] as List? ?? const []))
            if (e is Map) OldDesign.fromJson(Map<String, dynamic>.from(e)),
        ],
        lockNote: j['lock'] as String?,
        addOnTo: j['addOnTo'] as String?,
        serial: j['serial'] as int?,
        status: OrderStatus.values.firstWhere((s) => s.name == j['status'],
            orElse: () => OrderStatus.pending),
        photoChunksSent: (j['chunks'] ?? 0) as int,
        detailsSent: (j['details'] ?? false) as bool,
        dotsSent: (j['dots'] ?? j['details'] ?? false) as bool,
        noSent: (j['no'] ?? j['dots'] ?? j['details'] ?? false) as bool,
        awaitingAdvance: (j['hold'] ?? false) as bool,
        advancePaid: j['adv'] as int?,
        advanceUtr: j['advUtr'] as String?,
        tgChat: j['chat'] as String?,
        tgMsgId: (j['msgId'] as num?)?.toInt(),
        tgExtraIds: [for (final e in (j['extra'] as List? ?? const [])) (e as num).toInt()],
        registered: (j['reg'] ?? false) as bool,
        lastError: j['err'] as String?,
      );
}
