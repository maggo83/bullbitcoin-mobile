// BitSquiggles optional Flutter renderer and complete core facade.
// Grug 2-Clause License: do what want; not sue grug.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'bitsquiggle32.dart' as core;

export 'bitsquiggle32.dart';

Color _color(core.BitSquiggleColor color) =>
    Color(0xff000000 | int.parse(color.hex.substring(1), radix: 16));

/// Paint an exact integer-scaled pixel grid with antialiasing disabled.
void renderRaster(
  Canvas canvas,
  core.PixelGrid grid, {
  int pixelSize = 1,
  int offsetX = 0,
  int offsetY = 0,
}) {
  if (pixelSize <= 0) {
    throw ArgumentError.value(pixelSize, 'pixelSize', 'must be positive');
  }
  if (grid.width != core.pixelWidth ||
      grid.height != core.pixelHeight ||
      grid.pixels.length != core.pixelWidth * core.pixelHeight) {
    throw ArgumentError.value(grid, 'grid', 'must be a canonical 16x22 grid');
  }
  final background = Paint()
    ..color = _color(grid.background)
    ..isAntiAlias = false;
  final foreground = Paint()
    ..color = _color(grid.foreground)
    ..isAntiAlias = false;
  canvas.drawRect(
    Rect.fromLTWH(
      offsetX.toDouble(),
      offsetY.toDouble(),
      (grid.width * pixelSize).toDouble(),
      (grid.height * pixelSize).toDouble(),
    ),
    background,
  );
  for (var row = 0; row < grid.height; row++) {
    for (var column = 0; column < grid.width; column++) {
      if (grid.pixels[row * grid.width + column] == 0) continue;
      canvas.drawRect(
        Rect.fromLTWH(
          (offsetX + column * pixelSize).toDouble(),
          (offsetY + row * pixelSize).toDouble(),
          pixelSize.toDouble(),
          pixelSize.toDouble(),
        ),
        foreground,
      );
    }
  }
}

/// Paint a smooth presentation in the canonical 16x22 coordinate space.
void renderSmooth(Canvas canvas, core.VisualSpec visual, Size size) {
  if (size.width <= 0 || size.height <= 0) return;
  final scale = math.min(
    size.width / core.pixelWidth,
    size.height / core.pixelHeight,
  );
  final scaledWidth = core.pixelWidth * scale;
  final scaledHeight = core.pixelHeight * scale;
  final offsetX = (size.width - scaledWidth) / 2;
  final offsetY = (size.height - scaledHeight) / 2;

  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(offsetX, offsetY, scaledWidth, scaledHeight),
      Radius.circular(scale),
    ),
    Paint()..color = _color(visual.background),
  );

  final foregroundPath = Path()..fillType = PathFillType.nonZero;
  for (final blob in core.smoothBlobs(visual.connections)) {
    foregroundPath.addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          offsetX + (1 + blob.leftColumn * 3) * scale,
          offsetY + (1 + blob.topRow * 3) * scale,
          (2 + 3 * (blob.rightColumn - blob.leftColumn)) * scale,
          (2 + 3 * (blob.bottomRow - blob.topRow)) * scale,
        ),
        Radius.circular(scale),
      ),
    );
  }
  if (foregroundPath.computeMetrics().isNotEmpty) {
    canvas.drawPath(foregroundPath, Paint()..color = _color(visual.foreground));
  }
}

/// Reusable smooth renderer widget that consumes an already-derived spec.
final class BitSquiggleView extends StatelessWidget {
  const BitSquiggleView({
    required this.visual,
    this.width = 160,
    this.height = 220,
    super.key,
  });

  final core.VisualSpec visual;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width, height),
    painter: _BitSquigglePainter(visual),
  );
}

final class _BitSquigglePainter extends CustomPainter {
  const _BitSquigglePainter(this.visual);

  final core.VisualSpec visual;

  @override
  void paint(Canvas canvas, Size size) => renderSmooth(canvas, visual, size);

  @override
  bool shouldRepaint(_BitSquigglePainter oldDelegate) =>
      oldDelegate.visual != visual;
}
