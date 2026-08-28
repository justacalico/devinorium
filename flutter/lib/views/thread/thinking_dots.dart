part of '../thread_page.dart';

class _ThinkingDots extends StatefulWidget {
  final bool active;
  const _ThinkingDots({required this.active});

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _ThinkingDots old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        final dotCount = ((_controller.value * 3).floor() % 3) + 1;
        return Text('.' * dotCount);
      },
    );
  }
}
