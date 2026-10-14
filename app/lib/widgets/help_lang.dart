import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../l10n.dart';
import '../providers/providers.dart';

/// अ / A — switches the customer screens between Hindi and English.
class LangButton extends ConsumerWidget {
  const LangButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<bool>(
      valueListenable: hindiNotifier,
      builder: (_, hi, __) => IconButton(
        tooltip: hi ? 'English' : 'हिंदी',
        onPressed: () =>
            setHindi(ref.read(sharedPreferencesProvider), !hi),
        icon: Text(hi ? 'A' : 'अ',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

/// Help: WhatsApp or call customer care, with the design number filled in.
class HelpButton extends StatelessWidget {
  final String? designNumber;
  final Color? color;
  const HelpButton({super.key, this.designNumber, this.color});

  static Future<void> show(BuildContext context, {String? designNumber}) {
    final msg = designNumber == null
        ? t('Hello, I need help with the B.B SYNTHETICS app.',
            'नमस्ते, मुझे B.B SYNTHETICS ऐप में मदद चाहिए।')
        : t('Hello, I need help with design $designNumber.',
            'नमस्ते, मुझे डिज़ाइन $designNumber के बारे में मदद चाहिए।');
    return showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 14),
          Text(t('Need help?', 'मदद चाहिए?'),
              style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 6),
          ListTile(
            leading: const Icon(Icons.chat_rounded, color: Color(0xFF25D366), size: 30),
            title: Text(t('WhatsApp us', 'WhatsApp करें')),
            subtitle: const Text('+91 $kCustomerCareDisplay'),
            onTap: () {
              Navigator.pop(ctx);
              launchUrl(
                Uri.parse('https://wa.me/$kCustomerCareNumber?text=${Uri.encodeComponent(msg)}'),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.call_rounded, color: Color(0xFF1565C0), size: 30),
            title: Text(t('Call us', 'कॉल करें')),
            subtitle: const Text('+91 $kCustomerCareDisplay'),
            onTap: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse('tel:+$kCustomerCareNumber'));
            },
          ),
          const SizedBox(height: 10),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: t('Help', 'मदद'),
        icon: Icon(Icons.support_agent_rounded, color: color),
        onPressed: () => show(context, designNumber: designNumber),
      );
}

/// First open: let the customer pick the language (big, two buttons).
Future<void> askLanguageOnce(BuildContext context, WidgetRef ref) async {
  final prefs = ref.read(sharedPreferencesProvider);
  if (savedLanguage(prefs) != null) return;
  final hi = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('भाषा चुनें · Choose language', textAlign: TextAlign.center),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('हिंदी', style: TextStyle(fontSize: 22)),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('English', style: TextStyle(fontSize: 20)),
          ),
        ),
      ]),
    ),
  );
  await setHindi(prefs, hi ?? false);
}
