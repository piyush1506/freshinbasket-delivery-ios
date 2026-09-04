import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class DynamicSlideAction extends StatefulWidget {
  final Future<void> Function() onSubmit;
  final String text;

  const DynamicSlideAction({
    super.key,
    required this.onSubmit,
    this.text = 'Slide when reached',
  });

  @override
  State<DynamicSlideAction> createState() => _DynamicSlideActionState();
}

class _DynamicSlideActionState extends State<DynamicSlideAction> with SingleTickerProviderStateMixin {
  double _progress = 0.0;
  bool _submitted = false;
  final double _height = 64.0;

  @override
  Widget build(BuildContext context) {
    if (_submitted) {
      return const SizedBox(
        height: 64,
        child: Center(
          child: CircularProgressIndicator(color: AppTheme.primaryColor),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxDragDistance = constraints.maxWidth - _height;
        
        // Calculate dynamic color: starts white, ends green
        final Color thumbColor = Color.lerp(
          Colors.white, 
          Colors.green, 
          _progress
        ) ?? Colors.white;

        // Calculate icon color: starts primary color, ends white
        final Color iconColor = Color.lerp(
          AppTheme.primaryColor, 
          Colors.white, 
          _progress
        ) ?? AppTheme.primaryColor;

        return Container(
          height: _height,
          decoration: BoxDecoration(
            color: AppTheme.primaryColor,
            borderRadius: BorderRadius.circular(_height / 2),
          ),
          child: Stack(
            children: [
              // Background Text
              Center(
                child: Opacity(
                  opacity: (1.0 - _progress * 2).clamp(0.0, 1.0),
                  child: Text(
                    widget.text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              // Draggable Thumb
              Positioned(
                left: _progress * maxDragDistance,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  onHorizontalDragUpdate: (details) {
                    setState(() {
                      _progress += details.primaryDelta! / maxDragDistance;
                      _progress = _progress.clamp(0.0, 1.0);
                    });
                  },
                  onHorizontalDragEnd: (details) async {
                    if (_progress > 0.8) {
                      setState(() {
                        _progress = 1.0;
                        _submitted = true;
                      });
                      await widget.onSubmit();
                      if (mounted) {
                        setState(() {
                          _submitted = false;
                          _progress = 0.0;
                        });
                      }
                    } else {
                      setState(() {
                        _progress = 0.0;
                      });
                    }
                  },
                  child: Container(
                    width: _height,
                    height: _height,
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: thumbColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.location_on,
                      color: iconColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
