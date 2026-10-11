import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Owner (11-Oct-2026): the iPhone keyboard sometimes would not go away.
/// Whenever a keyboard is open, a big "HIDE KEYBOARD" button sits right on
/// top of it, on every screen; one tap closes it.
class KeyboardHideButton extends StatelessWidget {
  const KeyboardHideButton({super.key});

  static void hide() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom;
    if (kb <= 0) return const SizedBox.shrink();
    return Positioned(
      right: 10,
      bottom: kb + 8,
      child: Material(
        color: const Color(0xFF1B1A18),
        elevation: 6,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: hide,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.keyboard_hide_rounded, color: Colors.white, size: 22),
              SizedBox(width: 8),
              Text('HIDE KEYBOARD',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
            ]),
          ),
        ),
      ),
    );
  }
}
