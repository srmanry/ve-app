import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../domain/entities/timeline_item.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';

/// One lane of a secondary track (text, stickers, PIP or audio).
///
/// Tap selects an item. A selected item can be dragged to move it and its
/// edge handles resize it.
class TimelineLayerLane extends ConsumerWidget {
  const TimelineLayerLane({
    super.key,
    required this.kind,
    required this.items,
    required this.color,
    required this.icon,
    required this.label,
    required this.pps,
    required this.width,
    required this.visibleStart,
    required this.visibleEnd,
    required this.selection,
  });

  static const height = 30.0;

  final SelectionKind kind;
  final List<TimelineItem> items;
  final Color color;
  final IconData icon;
  final String Function(TimelineItem) label;
  final double pps;
  final double width;
  final Duration visibleStart;
  final Duration visibleEnd;
  final EditorSelection selection;

  double _x(Duration t) => t.inMicroseconds / 1e6 * pps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = <Widget>[];
    for (final item in items) {
      if (item.end < visibleStart || item.start > visibleEnd) continue;
      children.add(
        Positioned(
          left: _x(item.start),
          width: math.max(_x(item.duration), 8),
          top: 0,
          height: height,
          child: _LayerItem(
            key: ValueKey(item.id),
            target: EditorSelection(kind, item.id),
            item: item,
            color: color,
            icon: icon,
            label: label(item),
            pps: pps,
            selected: selection.isSelected(kind, item.id),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: width,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }
}

class _LayerItem extends ConsumerStatefulWidget {
  const _LayerItem({
    super.key,
    required this.target,
    required this.item,
    required this.color,
    required this.icon,
    required this.label,
    required this.pps,
    required this.selected,
  });

  final EditorSelection target;
  final TimelineItem item;
  final Color color;
  final IconData icon;
  final String label;
  final double pps;
  final bool selected;

  @override
  ConsumerState<_LayerItem> createState() => _LayerItemState();
}

class _LayerItemState extends ConsumerState<_LayerItem> {
  static const handleWidth = 12.0;
  late Duration _origStart, _origEnd;
  double _dx = 0;

  EditorController get _controller => ref.read(editorProvider.notifier);

  void _begin() {
    _controller.beginChange();
    _origStart = widget.item.start;
    _origEnd = widget.item.end;
    _dx = 0;
  }

  Duration get _delta => Duration(microseconds: (_dx / widget.pps * 1e6).round());

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return GestureDetector(
      onTap: () => _controller.select(widget.target),
      onHorizontalDragStart: selected ? (_) => _begin() : null,
      onHorizontalDragUpdate: selected
          ? (d) {
              _dx += d.delta.dx;
              _controller.moveLayer(widget.target, _origStart + _delta);
            }
          : null,
      child: Container(
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: selected ? 1 : 0.8),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? AppColors.selection : Colors.transparent, width: 2),
        ),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: selected ? handleWidth + 2 : 6),
              child: Row(
                children: [
                  Icon(widget.icon, size: 13, color: Colors.white),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: handleWidth,
                child: _handle(() {
                  _controller.resizeLayer(widget.target, newStart: _origStart + _delta);
                }),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: handleWidth,
                child: _handle(() {
                  _controller.resizeLayer(widget.target, newEnd: _origEnd + _delta);
                }),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _handle(VoidCallback onUpdate) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onHorizontalDragStart: (_) => _begin(),
    onHorizontalDragUpdate: (d) {
      _dx += d.delta.dx;
      onUpdate();
    },
    child: Container(
      decoration: BoxDecoration(color: AppColors.selection, borderRadius: BorderRadius.circular(3)),
      alignment: Alignment.center,
      child: Container(width: 2, height: 12, color: Colors.black54),
    ),
  );
}
