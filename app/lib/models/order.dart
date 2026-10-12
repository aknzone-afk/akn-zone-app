/// An order placed from the cart. Saved on the device (order history + the
/// send queue) and delivered to the shop's Telegram group by [OrderService].
library;

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
  String? lastError;

  Order({
    required this.number,
    required this.createdAt,
    required this.items,
    required this.customer,
    this.note = '',
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
    this.lastError,
  });

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
        lastError: j['err'] as String?,
      );
}
