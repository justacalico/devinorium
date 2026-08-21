import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A horizontally scrollable text view that does not participate in
/// vertical scroll gesture recognition. This lets an ancestor ListView
/// receive vertical drags and trackpad wheel events while still allowing
/// the user to drag long code lines left and right.
class HorizontalCodeView extends StatefulWidget {
  final InlineSpan textSpan;
  final TextStyle? textStyle;

  const HorizontalCodeView({
    super.key,
    required this.textSpan,
    this.textStyle,
  });

  @override
  State<HorizontalCodeView> createState() => _HorizontalCodeViewState();
}

class _HorizontalCodeViewState extends State<HorizontalCodeView> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Trackpad / mouse wheel: only act on horizontal components.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && event.scrollDelta.dx != 0) {
          final newOffset = _controller.offset - event.scrollDelta.dx;
          if (newOffset >= _controller.position.minScrollExtent &&
              newOffset <= _controller.position.maxScrollExtent) {
            _controller.jumpTo(newOffset);
          }
        }
      },
      child: RawGestureDetector(
        gestures: <Type, GestureRecognizerFactory>{
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(),
            (HorizontalDragGestureRecognizer instance) {
              instance.onUpdate = (details) {
                _controller.jumpTo(
                  _controller.offset - details.delta.dx,
                );
              };
            },
          ),
        },
        behavior: HitTestBehavior.translucent,
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Text.rich(
              widget.textSpan,
              style: widget.textStyle,
              softWrap: false,
            ),
          ),
        ),
      ),
    );
  }
}
