import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config.dart';
import '../models/filter_state.dart' as fs;
import '../providers/providers.dart';

class FilterSheet extends ConsumerStatefulWidget {
  const FilterSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const FilterSheet(),
    );
  }

  @override
  ConsumerState<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<FilterSheet> {
  late TextEditingController _minPriceCtrl;
  late TextEditingController _maxPriceCtrl;

  @override
  void initState() {
    super.initState();
    final filter = ref.read(filterProvider);
    final bounds = ref.read(priceBoundsProvider);

    final initialMin = filter.priceRange.min > 0
        ? filter.priceRange.min.round()
        : bounds.min.round();
    final initialMax = filter.priceRange.max.isFinite
        ? filter.priceRange.max.round()
        : bounds.max.round();
    _minPriceCtrl =
        TextEditingController(text: initialMin == 0 ? '' : '$initialMin');
    _maxPriceCtrl =
        TextEditingController(text: initialMax == 0 ? '' : '$initialMax');
  }

  @override
  void dispose() {
    _minPriceCtrl.dispose();
    _maxPriceCtrl.dispose();
    super.dispose();
  }

  void _applyPriceFromText() {
    final bounds = ref.read(priceBoundsProvider);
    final minStr = _minPriceCtrl.text.trim();
    final maxStr = _maxPriceCtrl.text.trim();
    var minV = double.tryParse(minStr) ?? bounds.min;
    var maxV = double.tryParse(maxStr) ?? bounds.max;
    if (minV < 0) minV = 0;
    if (maxV < minV) maxV = minV;
    // Clamp text values to bounds so the slider stays valid.
    minV = minV.clamp(bounds.min, bounds.max).toDouble();
    maxV = maxV.clamp(bounds.min, bounds.max).toDouble();
    ref.read(filterProvider.notifier).setPriceRange(fs.RangeValues(minV, maxV));
  }

  void _syncTextFromSlider(RangeValues v) {
    final newMin = '${v.start.round()}';
    final newMax = '${v.end.round()}';
    if (_minPriceCtrl.text != newMin) {
      _minPriceCtrl.text = newMin;
      _minPriceCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: _minPriceCtrl.text.length));
    }
    if (_maxPriceCtrl.text != newMax) {
      _maxPriceCtrl.text = newMax;
      _maxPriceCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: _maxPriceCtrl.text.length));
    }
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(filterProvider);
    final bounds = ref.watch(priceBoundsProvider);

    final currentMin =
        filter.priceRange.min.clamp(bounds.min, bounds.max).toDouble();
    final currentMax = filter.priceRange.max.isFinite
        ? filter.priceRange.max.clamp(bounds.min, bounds.max).toDouble()
        : bounds.max;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 4,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  UText('Filter',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  // One-tap reset: category, price range and sort all go back
                  // to their defaults.
                  TextButton.icon(
                    onPressed: () {
                      ref.read(filterProvider.notifier).clear();
                      final b = ref.read(priceBoundsProvider);
                      _minPriceCtrl.text = '${b.min.round()}';
                      _maxPriceCtrl.text = '${b.max.round()}';
                      setState(() {});
                    },
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const UText('Clear all'),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // ---------- Category ----------
              UText('Category', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final cat in kFabricCategories)
                    FilterChip(
                      label: UText(cat.label),
                      selected: filter.categories.contains(cat.key),
                      onSelected: (_) => ref
                          .read(filterProvider.notifier)
                          .toggleCategory(cat.key),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // ---------- Price range ----------
              UText('Price range',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _minPriceCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: false),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        prefixText: '₹ ',
                        labelText: 'Min',
                        isDense: true,
                        // Matches the Max field's helper line so both inputs are
                        // the same height and line up.
                        helperText: 'Catalog min ₹${bounds.min.round()}',
                      ),
                      onChanged: (_) => _applyPriceFromText(),
                      onEditingComplete: _applyPriceFromText,
                      // iOS's number pad has no Done key — tapping anywhere
                      // outside the field closes it so Show Results is
                      // reachable again.
                      onTapOutside: (_) =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: UText('—',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _maxPriceCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: false),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        prefixText: '₹ ',
                        labelText: 'Max',
                        isDense: true,
                        helperText: 'Catalog max ₹${bounds.max.round()}',
                      ),
                      onChanged: (_) => _applyPriceFromText(),
                      onEditingComplete: _applyPriceFromText,
                      onTapOutside: (_) =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              RangeSlider(
                values: RangeValues(currentMin, currentMax),
                min: bounds.min,
                max: bounds.max,
                divisions:
                    ((bounds.max - bounds.min) / 50).round().clamp(2, 200),
                labels: RangeLabels(
                    '₹${currentMin.round()}', '₹${currentMax.round()}'),
                onChanged: (v) {
                  // Slider always uses the actual max — no more "infinity = no max".
                  ref.read(filterProvider.notifier).setPriceRange(
                        fs.RangeValues(v.start, v.end),
                      );
                  _syncTextFromSlider(v);
                },
              ),

              const SizedBox(height: 16),

              // ---------- Sort ----------
              UText('Sort by', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final opt in [
                    (fs.SortBy.priceAsc, 'Price: Low to High'),
                    (fs.SortBy.priceDesc, 'Price: High to Low'),
                    (fs.SortBy.modifiedDesc, 'New to Old'),
                  ])
                    ChoiceChip(
                      label: UText(opt.$2),
                      selected: filter.sortBy == opt.$1,
                      // Tapping the already-selected chip turns the price sort
                      // OFF and returns to the default shuffled order.
                      onSelected: (_) => ref
                          .read(filterProvider.notifier)
                          .setSort(filter.sortBy == opt.$1
                              ? fs.SortBy.shuffle
                              : opt.$1),
                    ),
                ],
              ),

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.search, size: 18),
                  onPressed: () {
                    // Close the sheet, then push (not replace) the all-
                    // results grid so the back button / system gesture
                    // returns to home instead of exiting the app.
                    Navigator.pop(context);
                    context.push('/folder/_all');
                  },
                  label: const UText('Show results'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
