import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Frame for a tool panel shown in place of the tool bar.
class ToolPanel extends StatelessWidget {
  const ToolPanel({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
          child: Row(
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              ...actions,
              IconButton(
                tooltip: 'Done',
                onPressed: onClose,
                icon: const Icon(Icons.check_rounded),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: child,
          ),
        ),
      ],
    );
  }
}

/// Message shown when a panel needs a selection first.
class PanelHint extends StatelessWidget {
  const PanelHint(this.text, {super.key, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

/// Labelled slider that reports gesture start (for undo checkpoints).
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onChangeStart,
    this.format,
    this.divisions,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final String Function(double)? format;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final text = format?.call(value) ?? value.toStringAsFixed(2);
    return Row(
      children: [
        SizedBox(width: 92, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: text,
            onChangeStart: onChangeStart,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(text, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}

/// Horizontal list of choice chips.
class ChipRow<T> extends StatelessWidget {
  const ChipRow({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> values;
  final T? selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final v in values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(label(v)),
              selected: v == selected,
              onSelected: (_) => onSelected(v),
            ),
          ),
      ],
    ),
  );
}

/// Round icon+label action button used in panels.
class PanelAction extends StatelessWidget {
  const PanelAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: c, size: 22),
              ),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 11, color: c)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Palette used by text/sticker/canvas colour pickers.
const kSwatches = <int>[
  0xFFFFFFFF,
  0xFF000000,
  0xFFFF5A5F,
  0xFFFFD166,
  0xFF06D6A0,
  0xFF5B8CFF,
  0xFF8B5CF6,
  0xFFFF8FAB,
  0xFFFF9F1C,
  0xFF2EC4B6,
  0xFF3A3A3A,
  0xFF9CA3AF,
];

class ColorSwatchRow extends StatelessWidget {
  const ColorSwatchRow({
    super.key,
    required this.selected,
    required this.onSelected,
    this.allowNone = false,
  });

  final int? selected;
  final ValueChanged<int?> onSelected;
  final bool allowNone;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        if (allowNone)
          _swatch(context, null, child: const Icon(Icons.block, size: 18, color: Colors.white70)),
        for (final c in kSwatches) _swatch(context, c),
      ],
    ),
  );

  Widget _swatch(BuildContext context, int? color, {Widget? child}) {
    final isSelected = selected == color;
    return GestureDetector(
      onTap: () => onSelected(color),
      child: Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: color == null ? Colors.transparent : Color(color),
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? AppColors.selection : Colors.white24,
            width: isSelected ? 3 : 1,
          ),
        ),
        child: child,
      ),
    );
  }
}
