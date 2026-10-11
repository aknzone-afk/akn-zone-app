import 'package:flutter/widgets.dart';

/// Drop-in replacement for [Text] that renders its content in UPPERCASE, so all
/// copy in the app is capitalised. Every `Text(...)` in lib/ is swapped to this.
class UText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final TextScaler? textScaler;
  final TextDirection? textDirection;
  final StrutStyle? strutStyle;
  final String? semanticsLabel;
  final Locale? locale;

  const UText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.textScaler,
    this.textDirection,
    this.strutStyle,
    this.semanticsLabel,
    this.locale,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      data.toUpperCase(),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textScaler: textScaler,
      textDirection: textDirection,
      strutStyle: strutStyle,
      semanticsLabel: semanticsLabel,
      locale: locale,
    );
  }
}
