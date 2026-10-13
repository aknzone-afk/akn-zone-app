import 'package:package_info_plus/package_info_plus.dart';
import 'dart:convert';
import 'dart:io';

import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';
import '../services/access_api.dart';
import '../services/account_service.dart';
import '../services/device_binding.dart';
import '../services/push_service.dart';
import 'onboarding_screen.dart';
import '../theme.dart';

const String _kPhone = 'access_phone';

/// ============================================================
/// GATE — wraps the whole app (see app.dart). Order:
///   force-update? → signed in? → approved? → catalog.
/// With [kAccessControlEnabled] false this is a transparent no-op,
/// so the app keeps working while the backend is being set up.
/// ============================================================
class AuthGate extends StatefulWidget {
  final Widget child;
  const AuthGate({super.key, required this.child});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _Gate {
  loading,
  forceUpdate,
  onboarding, // owner 14-Oct: WhatsApp verify → claim / sign up → approval
  accountRemoved, // account blocked by the shop
  accountDeclined, // sign-up not approved
  login,
  register,
  pending,
  removed,
  deviceConflict,
  allowed,
}

/// Set by the live AuthGate so flows that sit outside its subtree (deleting the
/// account from Settings) can make the gate re-evaluate itself.
VoidCallback? _gateRefresh;

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  _Gate _state = _Gate.loading;
  String _phone = '';
  bool _resolving = false;
  bool _checkedForceUpdate = false;
  bool _checkedMinBuild = false;
  bool _preloaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gateRefresh = () => _resolve();
    _resolve();
  }

  @override
  void dispose() {
    _gateRefresh = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Re-check on resume, but a customer who is already inside must keep seeing
    // the catalog while it happens — see the `silent` handling in _resolve.
    if (s == AppLifecycleState.resumed) {
      _resolve(silent: _state == _Gate.allowed);
    }
  }

  /// [silent] re-validates in the background without collapsing the UI to a
  /// spinner. Showing the spinner unmounts widget.child — which is the whole
  /// Router subtree — so a plain resume would otherwise tear the catalog down,
  /// lose the customer's place, and make them wait on two sheet downloads.
  /// Owner 13-Oct: an app older than app-config.json's min_build must update
  /// (works even with the customer sheet switched off). Offline = let in.
  static Future<bool> _belowMinBuild() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final rq = await c.getUrl(Uri.parse('$kAppConfigUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 300000}'));
      final rs = await rq.close().timeout(const Duration(seconds: 8));
      final j = jsonDecode(await rs.transform(utf8.decoder).join()) as Map<String, dynamic>;
      c.close();
      // Owner's LIVE TEST (₹5 token, no minimum) — on/off from the website.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('live_test_v1', j['live_test'] == true);
      final min = (j[Platform.isIOS ? 'min_build_ios' : 'min_build_android'] as num?)?.toInt() ?? 0;
      final mine = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
      return mine > 0 && mine < min;
    } catch (_) {
      return false;
    }
  }

  /// Owner 14-Oct: customer onboarding. Null = an approved account (go on to
  /// the catalog); otherwise the gate screen to show. An approved account is
  /// re-checked in the background (offline = let in); a blocked / declined
  /// one is asked again before the removed screen, in case the shop undid it.
  Future<_Gate?> _accountGate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final a = AccountService.saved(prefs);
      final status = '${a?['status'] ?? ''}';
      if (a == null || status.isEmpty) return _Gate.onboarding;
      if (status == 'approved') {
        // ignore: discarded_futures
        _recheckAccount(prefs, a);
        return null;
      }
      if (status == 'blocked' || status == 'declined') {
        final d = await AccountService.checkStatus('${a['mobile'] ?? ''}');
        final now = '${d?['status'] ?? ''}';
        if (now == 'approved') {
          await AccountService.approve(prefs, {
            ...a,
            if (d?['kind'] != null) 'kind': d!['kind'],
            if (d?['party'] != null) 'party': d!['party'],
            if (d?['cust'] is Map) 'cust': d!['cust'],
          });
          return null;
        }
        if (now == 'pending') {
          await AccountService.save(prefs, {...a, 'status': 'pending'});
          return _Gate.onboarding;
        }
        if (now == 'blocked' || now == 'declined') {
          await AccountService.save(prefs, {...a, 'status': now});
          return now == 'blocked' ? _Gate.accountRemoved : _Gate.accountDeclined;
        }
        return status == 'blocked' ? _Gate.accountRemoved : _Gate.accountDeclined;
      }
      return _Gate.onboarding; // pending → the flow shows "waiting for approval"
    } catch (_) {
      return null; // never lock a customer out because of an app error
    }
  }

  bool _rechecking = false;

  /// Background check of an approved account (every cold start / resume).
  Future<void> _recheckAccount(SharedPreferences prefs, Map<String, dynamic> a) async {
    if (_rechecking) return;
    _rechecking = true;
    try {
      // ignore: discarded_futures
      PushService.register(prefs, AccountService.dio);
      final d = await AccountService.checkStatus('${a['mobile'] ?? ''}');
      final now = '${d?['status'] ?? ''}';
      if (now != 'blocked' && now != 'declined') return; // offline / fine → stay in
      await AccountService.save(prefs, {...a, 'status': now});
      if (mounted) {
        setState(() => _state = now == 'blocked' ? _Gate.accountRemoved : _Gate.accountDeclined);
      }
    } catch (_) {
    } finally {
      _rechecking = false;
    }
  }

  Future<void> _resolve({bool silent = false}) async {
    if (!_checkedMinBuild) {
      _checkedMinBuild = true;
      if (await _belowMinBuild()) {
        if (mounted) setState(() => _state = _Gate.forceUpdate);
        return;
      }
    }
    if (_state == _Gate.forceUpdate) return;
    final acct = await _accountGate();
    if (acct != null) {
      if (mounted) setState(() => _state = acct);
      return;
    }
    if (!kAccessControlEnabled || !AccessApi.isConfigured) {
      if (mounted) setState(() => _state = _Gate.allowed);
      return;
    }
    if (_resolving) return;
    _resolving = true;
    try {
      if (!silent && mounted) setState(() => _state = _Gate.loading);

      // Force-update is a cold-start question. Running it on every resume put a
      // second serial round trip in front of the catalog for no benefit.
      if (!_checkedForceUpdate) {
        _checkedForceUpdate = true;
        if (await AccessApi.needsForceUpdate()) {
          if (mounted) setState(() => _state = _Gate.forceUpdate);
          return;
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final phone = prefs.getString(_kPhone);
      if (phone == null || phone.isEmpty) {
        if (mounted) setState(() => _state = _Gate.login);
        return;
      }
      _phone = phone;

      _Gate next;
      try {
        final wasPending = await AccessApi.cachedStatus() == 'pending';
        final status = await AccessApi.checkStatus(_phone);
        final effective =
            (status == 'not_found' && wasPending) ? 'pending' : status;
        await AccessApi.cacheStatus(effective);
        switch (effective) {
          case 'approved':
            final bindResult = await DeviceBinding.bind(_phone);
            next =
                bindResult == 'conflict' ? _Gate.deviceConflict : _Gate.allowed;
          case 'pending':
            next = _Gate.pending;
          case 'removed':
            await prefs.remove(_kPhone);
            next = _Gate.removed;
          default:
            next = _Gate.register;
        }
      } catch (_) {
        final cached = await AccessApi.cachedStatus();
        next = switch (cached) {
          'approved' => _Gate.allowed,
          'pending' => _Gate.pending,
          'removed' => _Gate.removed,
          _ => silent ? _state : _Gate.login,
        };
      }
      if (mounted) setState(() => _state = next);
    } finally {
      _resolving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _Gate.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case _Gate.forceUpdate:
        return const ForceUpdateScreen();
      // The gate sits above the app's router, so these screens get their own
      // Navigator (dialogs, bottom sheets, autocomplete overlays need one).
      // Distinct keys → a fresh Navigator when the screen kind changes.
      case _Gate.onboarding:
        // Owner 14-Oct: the catalogue downloads in the background while the
        // customer signs up / waits; it is only SHOWN once approved.
        if (!_preloaded) {
          _preloaded = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            try {
              ProviderScope.containerOf(context, listen: false).read(catalogProvider.future).ignore();
            } catch (_) {}
          });
        }
        return _OwnNavigator(
            key: const ValueKey('gate-onboarding'),
            child: OnboardingFlow(onDone: _resolve));
      case _Gate.accountRemoved:
      case _Gate.accountDeclined:
        final declined = _state == _Gate.accountDeclined;
        return _OwnNavigator(
            key: ValueKey('gate-removed-$declined'),
            child: AccountRemovedScreen(declined: declined, onRetry: _resolve));
      case _Gate.login:
        return PhoneLoginScreen(onDone: _resolve);
      case _Gate.register:
        return RegistrationScreen(phone: _phone, onDone: _resolve);
      case _Gate.pending:
        return PendingScreen(onRefresh: _resolve);
      case _Gate.removed:
        return RemovedScreen(onRetry: _resolve);
      case _Gate.deviceConflict:
        return DeviceConflictScreen(phone: _phone, onRetry: _resolve);
      case _Gate.allowed:
        return widget.child;
    }
  }
}

/// Owner 14-Oct: makes the gate look again (after "Log out / change number").
void refreshAccessGate() => _gateRefresh?.call();

/// A one-page Navigator for gate screens shown above the app's router.
class _OwnNavigator extends StatelessWidget {
  final Widget child;
  const _OwnNavigator({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child),
      );
}

/// Serif wordmark shared by the gate screens.
class _GateWordmark extends StatelessWidget {
  const _GateWordmark();
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const UText(
          'AKN Zone',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Playfair',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.0,
            color: kInk,
          ),
        ),
      ],
    );
  }
}

/// ============================================================
/// PHONE LOGIN — enter number, verify against the Sheet
/// ============================================================
class PhoneLoginScreen extends StatefulWidget {
  final VoidCallback onDone;
  const PhoneLoginScreen({super.key, required this.onDone});
  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final _phoneCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _continue() async {
    final digits = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) {
      setState(() => _error = 'Please enter a valid 10-digit number');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final phone = digits.substring(digits.length - 10);
    try {
      final status = await AccessApi.checkStatus(phone);
      await AccessApi.cacheStatus(status);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPhone, phone);
      widget.onDone();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not verify. Check your internet and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _GateWordmark(),
                  const SizedBox(height: 44),
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    maxLength: 10,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Registered Mobile Number',
                      prefixText: '+91  ',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _continue(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: _busy ? null : _continue,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const UText('Continue'),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    UText(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFB3261E)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ============================================================
/// REGISTRATION — firm + city → WhatsApp request to owner
/// ============================================================
class RegistrationScreen extends StatefulWidget {
  final String phone;
  final VoidCallback onDone;
  const RegistrationScreen(
      {super.key, required this.phone, required this.onDone});
  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _firmCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_firmCtrl.text.trim().isEmpty || _cityCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Please fill both firm name and city');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Register automatically via the backend.
      await AccessApi.register(
        phone: widget.phone,
        firm: _firmCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
      );
      // Also send WhatsApp so the owner gets a notification.
      final link = AccessApi.registrationWhatsAppLink(
        phone: widget.phone,
        firm: _firmCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
      );
      await launchUrl(link, mode: LaunchMode.externalApplication);
      await AccessApi.cacheStatus('pending');
      widget.onDone();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not register. Check your internet and try again.';
      });
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPhone);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const UText('Register')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UText(
                'Enter your details to request access',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    letterSpacing: 1.0,
                    fontSize: 12),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _firmCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Firm Name'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _cityCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'City'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: TextEditingController(text: '+91 ${widget.phone}'),
                enabled: false,
                decoration: const InputDecoration(labelText: 'Mobile Number'),
              ),
              const SizedBox(height: 28),
              SizedBox(
                height: 50,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const UText('Request access via WhatsApp'),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _logout,
                child: const UText('Use a different number'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                UText(_error!,
                    style: const TextStyle(color: Color(0xFFB3261E))),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// ============================================================
/// PENDING / REMOVED / FORCE-UPDATE
/// ============================================================
class _GateNotice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;
  const _GateNotice({
    required this.icon,
    required this.title,
    required this.message,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 64, color: scheme.outline),
                const SizedBox(height: 24),
                UText(title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                UText(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      height: 1.6,
                      letterSpacing: 0.6),
                ),
                const SizedBox(height: 28),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PendingScreen extends StatelessWidget {
  final VoidCallback onRefresh;
  const PendingScreen({super.key, required this.onRefresh});
  @override
  Widget build(BuildContext context) {
    return _GateNotice(
      icon: Icons.hourglass_top_rounded,
      title: 'Approval pending',
      message:
          'Your request has been sent. The catalog will open as soon as your access is approved. Please check back shortly.',
      actions: [
        OutlinedButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const UText('Check again'),
        ),
        TextButton(
          onPressed: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(_kPhone);
            onRefresh();
          },
          child: const UText('Use a different number'),
        ),
      ],
    );
  }
}

class RemovedScreen extends StatelessWidget {
  final VoidCallback onRetry;
  const RemovedScreen({super.key, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return _GateNotice(
      icon: Icons.lock_outline_rounded,
      title: 'Access not available',
      message:
          'Your access is currently not available. Please contact AKN Zone for details.',
      actions: [
        OutlinedButton(onPressed: onRetry, child: const UText('Try again')),
      ],
    );
  }
}

class ForceUpdateScreen extends StatelessWidget {
  const ForceUpdateScreen({super.key});

  static const String _androidUrl =
      'https://play.google.com/store/apps/details?id=com.bbsynthetics.catalog_app';
  static const String _iosUrl = 'https://apps.apple.com/app/id6776107523';

  Future<void> _open() async {
    final url = Platform.isIOS ? _iosUrl : _androidUrl;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return _GateNotice(
      icon: Icons.system_update_alt_rounded,
      title: 'Update required',
      message:
          'A new version of the app is available. Please update to continue.',
      actions: [
        FilledButton(onPressed: _open, child: const UText('Update now')),
      ],
    );
  }
}

/// ============================================================
/// DEVICE CONFLICT — number is already bound to 2 other devices
/// ============================================================
class DeviceConflictScreen extends StatelessWidget {
  final String phone;
  final VoidCallback onRetry;
  const DeviceConflictScreen(
      {super.key, required this.phone, required this.onRetry});

  Future<void> _requestTransfer() async {
    final msg = 'DEVICE TRANSFER REQUEST\n'
        'Mobile: $phone\n'
        'I need to transfer my catalog access to this device. '
        'Please clear my device binding.';
    final link = Uri.parse(
        'https://wa.me/${AccessApi.ownerWhatsApp}?text=${Uri.encodeComponent(msg)}');
    await launchUrl(link, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return _GateNotice(
      icon: Icons.devices_other_rounded,
      title: 'Active on another device',
      message:
          'This number is already in use on the maximum number of devices. '
          'Please contact AKN Zone to transfer your access to this device.',
      actions: [
        FilledButton.icon(
          onPressed: _requestTransfer,
          icon: const Icon(Icons.message_rounded, size: 18),
          label: const UText('Request transfer via WhatsApp'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: onRetry, child: const UText('Try again')),
        TextButton(
          onPressed: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(_kPhone);
            onRetry();
          },
          child: const UText('Use a different number'),
        ),
      ],
    );
  }
}

/// ============================================================
/// DELETE ACCOUNT (Apple requirement)
/// ============================================================
Future<void> deleteMyAccount(BuildContext context) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const UText('Delete account?'),
      content: const UText(
          'Your access data will be removed from this device. Are you sure?'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const UText('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child:
              const UText('Delete', style: TextStyle(color: Color(0xFFB3261E))),
        ),
      ],
    ),
  );
  if (confirm != true) return;

  final prefs = await SharedPreferences.getInstance();
  final phone = prefs.getString(_kPhone) ?? '';
  await prefs.remove(_kPhone);
  await AccessApi.cacheStatus('not_found');
  if (phone.isNotEmpty) await DeviceBinding.unbind(phone);
  await DeviceBinding.clearLocal();
  // Otherwise the customer is left sitting in the full catalog with no sign
  // anything happened; kick the gate so it drops back to the login screen.
  _gateRefresh?.call();
}
