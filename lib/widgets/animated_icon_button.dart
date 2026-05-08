import 'package:flutter/material.dart';

/// An IconButton that scales down when pressed for tactile feedback
class AnimatedIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final double? iconSize;

  const AnimatedIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.color,
    this.iconSize,
  });

  @override
  State<AnimatedIconButton> createState() => _AnimatedIconButtonState();
}

class _AnimatedIconButtonState extends State<AnimatedIconButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.85).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.onPressed == null) return;

    // Call the callback immediately — the visual animation (scale down/up)
    // is already driven by onTapDown/onTapUp on the GestureDetector.
    // Awaiting the animation here caused a ~200ms delay and conflicted
    // with the onTapUp reverse animation running simultaneously.
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) => _controller.reverse(),
      onTapCancel: () => _controller.reverse(),
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: IconButton(
          icon: Icon(widget.icon),
          color: widget.color,
          iconSize: widget.iconSize,
          onPressed: _handleTap,
        ),
      ),
    );
  }
}
