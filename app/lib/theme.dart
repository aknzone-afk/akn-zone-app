import 'package:flutter/material.dart';

/// Luxury fashion-house theme: pure white "paper", near-black ink, a single
/// champagne-gold accent, hairline borders and generous letter-spacing. The
/// saree photos are the only colour on screen — everything else stays quiet,
/// like a designer label's lookbook.
const Color kInk = Color(0xFF1B1A18); // near-black ink
const Color kGold = Color(0xFFB69355); // champagne gold accent
const Color kPaper = Color(0xFFFFFFFF); // pure white
const Color kHairline = Color(0xFFE8E3DA); // warm hairline border
const Color kLinen = Color(0xFFF7F5F1); // faint warm fill

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kInk,
    brightness: Brightness.light,
  ).copyWith(
    primary: kInk,
    onPrimary: Colors.white,
    secondary: kGold,
    onSecondary: Colors.white,
    surface: kPaper,
    onSurface: kInk,
    surfaceContainerLowest: const Color(0xFFFCFBF9),
    surfaceContainerLow: kLinen,
    outlineVariant: kHairline,
    primaryContainer: kInk, // selected chips read as black labels
    onPrimaryContainer: Colors.white,
  );

  // Chip text flips to white when the chip is selected (black pill).
  final chipLabelColor = WidgetStateColor.resolveWith(
      (states) => states.contains(WidgetState.selected) ? Colors.white : kInk);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kPaper,
    appBarTheme: const AppBarTheme(
      backgroundColor: kPaper,
      foregroundColor: kInk,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      // Serif display type — the fashion-editorial wordmark look. All copy
      // renders uppercase (UText), so this reads like a magazine masthead.
      // liningFigures: Playfair's default digits are old-style (small, low-
      // hanging) which misalign next to capitals — force full-height digits.
      titleTextStyle: TextStyle(
        fontFamily: 'Playfair',
        color: kInk,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.6,
        fontFeatures: [FontFeature.liningFigures()],
      ),
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(
          fontFamily: 'Playfair',
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: kInk,
          fontFeatures: [FontFeature.liningFigures()]),
      titleMedium: TextStyle(
          fontFamily: 'Playfair',
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: kInk,
          fontFeatures: [FontFeature.liningFigures()]),
      // Eyebrow labels (section headers like CATEGORY / PRICE RANGE) stay in
      // tracked-out sans — the classic pairing under a serif display face.
      titleSmall: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 2.6,
          color: kInk),
      bodySmall: TextStyle(letterSpacing: 0.6),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: kPaper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: kHairline, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: kInk.withValues(alpha: 0.30), width: 0.8),
      backgroundColor: kPaper,
      selectedColor: kInk,
      checkmarkColor: Colors.white,
      showCheckmark: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      labelStyle: TextStyle(
        color: chipLabelColor,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.1,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: const Color(0xFFFCFBF9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: kHairline, width: 0.8),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: kHairline, width: 0.8),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: kInk, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kInk,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        textStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 2.0),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: kInk,
        textStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.2),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: kInk,
      foregroundColor: Colors.white,
      extendedTextStyle:
          TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.6),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      backgroundColor: kPaper,
      surfaceTintColor: kPaper,
    ),
    dividerTheme: const DividerThemeData(color: kHairline, thickness: 0.8),
  );
}
