import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';

/// "What's new" — the list of improvements in this version, linked from the
/// bottom of the cart and the order screen.
class WhatsNewScreen extends StatelessWidget {
  const WhatsNewScreen({super.key});

  static const _customer = <(String, String, String)>[
    ('🛒', 'ORDER NOW in the cart',
        'Send your whole selection to us in one tap — no need to forward photos on WhatsApp.'),
    ('🎯', 'Minimum order ₹30,000',
        'The bar shows the value so far, e.g. ₹12,000 / ₹30,000. Below ₹30,000 the app asks you to add a few more designs.'),
    ('🧮', 'Pieces counted from the photo',
        'Each design counts every saree in its photo — the open one plus each folded colour — so the value is right.'),
    ('➕', 'Add to your parcel (2 days)',
        'After you order, you can add more designs to the SAME parcel today and tomorrow — no ₹30,000 minimum for these add-ons.'),
    ('🏪', 'Old customer: just your mobile',
        'Choose OLD CUSTOMER, type your mobile and tap FIND — your party details come from our records automatically.'),
    ('🆕', 'New customer: full details',
        'Choose NEW CUSTOMER and fill every field (only GST / PAN / Aadhaar is optional).'),
    ('⛔', 'Minimum ₹30,000 is strict',
        'The box turns red below ₹30,000 and the order cannot be sent until you add more.'),
    ('📁', 'DONE takes you back',
        'After selecting from a design, DONE returns you to the same folder to keep choosing.'),
    ('🖼️', 'Cart shows your selection',
        'After DONE, the cart photo shows your green numbers and SET exactly as the shop will see them.'),
    ('📖', 'Picture guide',
        'The first time you select, a simple guide shows how: tap = 1 piece, tap again = 2, SET = all colours.'),
    ('🔁', 'Order again',
        'My Orders → "Order again" puts that order\'s designs back in your cart.'),
    ('🟩', 'One DO SELECTION button',
        'Every design has one clear DO SELECTION box (no small round icons). It opens the photo — tap the colours you want.'),
    ('👆', 'Tap to select pieces',
        'In the cart, tap a design: tap a saree = 1, again = 2, 3… (only sarees can be tapped). − SET + below = sets (1 set = one of every colour). Hold a number to type any quantity. Undo at the top.'),
    ('✔️', 'Your marks are understood',
        'Tick or line on a saree = only those; cross = not wanted; write a number (2, 3…) on a saree = that many pieces. The app reads your marks and counts the pieces.'),
    ('🔢', 'Pieces for each design',
        'Use + / − or tap the number to type how many pieces you want.'),
    ('✖️', 'Remove from this order only',
        'Drop a design from the order without losing it from your cart (Undo available).'),
    ('💾', 'Your details are remembered',
        'Next time just check and send. Ordering for another party? Tap "New party".'),
    ('📱', 'Mobile number check',
        'India: 10 digits starting with 6, 7, 8 or 9 (+91 / 0 removed automatically). Outside India: any number with country code.'),
    ('📮', 'Pincode check (India Post)',
        'Shows the city and state, fills Booking Place for you, warns if they don\'t match and stops a wrong pincode.'),
    ('🚚', 'Transport list',
        'Pick from 428 transports (search any word of the name) — or type your own.'),
    ('🧾', 'GST / PAN / Aadhaar (optional)',
        'Recognised automatically and the format is checked.'),
    ('📝', 'Message for us',
        'Colour, delivery date, packing — anything extra goes with the order.'),
    ('🖍️', 'Photos go exactly as you marked them',
        'Your ticks and markings on the photos reach us as they are.'),
    ('🔒', 'Never lose an order',
        'No internet? The order is saved on your phone and sent automatically later. See My Orders for the status.'),
    ('🔗', 'Open designs from videos',
        'Links like bbsynthetics.in/d/1444 open that design straight in the app. One link can carry many designs.'),
  ];

  static const _owner = <(String, String, String)>[
    ('📷', 'Photos first, then details',
        'Each order arrives as its photos (10 per album) — every photo captioned with D.No, price, pieces and folder — followed by one message with all the customer details and a ━━━ line.'),
    ('🎯', 'Only orders of ₹30,000+',
        'Price × pieces is checked in the app (same rule as AKN Chat). If a design has no price the order still comes, marked ⚠️ so you can check.'),
    ('🎯', 'Numbers on a clear spot',
        'Each number sits on a plain part of its own saree — never between two sarees.'),
    ('🧾', 'Clear total on the photo',
        'A dark line shows e.g. "2 SET (12) + 8 SELECTED = 20 SAREES".'),
    ('🔢', 'Serial order numbers',
        'Every order in the group ends with ORDER NO. 1, 2, 3… and two dots, then the next order.'),
    ('➕', 'Add-on orders marked',
        'Orders added within 2 days arrive as "ADD-ON to order …" so they go in the same parcel.'),
    ('💬', 'One-tap WhatsApp',
        'The mobile number in the order has a WhatsApp link — tap it to message the customer for the bill.'),
    ('🧮', 'Totals at the top',
        'Number of designs, total pieces and approximate value (from catalog prices).'),
    ('🔖', 'Order number',
        'Every order has its own number (e.g. AKN-1110-1215-K7Q), shown to the customer too.'),
    ('🌍', 'Foreign orders stand out',
        'Orders from outside India show the country in bold at the top.'),
    ('♻️', 'No duplicate photos',
        'If a send is interrupted, the retry continues where it stopped.'),
    ('🔑', 'Bot can be changed without a new app',
        'The Telegram bot and group are read from the website, so they can be replaced any time.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const UText("What's new")),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          const UText('For customers',
              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          for (final e in _customer) _Item(e),
          const SizedBox(height: 18),
          const UText('For the shop (in Telegram)',
              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          for (final e in _owner) _Item(e),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  final (String, String, String) e;
  const _Item(this.e);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 32, child: Text(e.$1, style: const TextStyle(fontSize: 20))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(e.$3, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
