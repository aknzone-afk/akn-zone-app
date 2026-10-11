import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/geofence_service.dart';

/// Full-screen "Not available in your region" lock. Hosts a 4-digit PIN field
/// so the shop can bypass with the rotating daily code.
class GeofenceLockScreen extends ConsumerStatefulWidget {
  const GeofenceLockScreen({super.key});

  @override
  ConsumerState<GeofenceLockScreen> createState() => _GeofenceLockScreenState();
}

class _GeofenceLockScreenState extends ConsumerState<GeofenceLockScreen> {
  final _ctrl = TextEditingController();
  bool _wrong = false;
  bool _checking = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _wrong = false;
    });
    final prefs = ref.read(sharedPreferencesProvider);
    final r = await GeofenceService.tryBypass(_ctrl.text, prefs);
    if (!mounted) return;
    if (r.ok) {
      // Force the gate to re-evaluate; bypass is now active.
      ref.invalidate(geofenceAllowedProvider);
    } else {
      setState(() {
        _wrong = true;
        _checking = false;
      });
      _ctrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline_rounded,
                    size: 72, color: scheme.outline),
                const SizedBox(height: 32),
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _ctrl,
                    keyboardType: TextInputType.text,
                    textAlign: TextAlign.center,
                    maxLength: 5,
                    obscureText: true,
                    inputFormatters: [
                      // Allow digits + optional slash so users can type "18/05".
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9/]')),
                    ],
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 6,
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '••••',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      errorText: _wrong ? 'Wrong code' : null,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: 240,
                  height: 50,
                  child: FilledButton(
                    onPressed: _checking ? null : _submit,
                    child: _checking
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const UText('UNLOCK'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
