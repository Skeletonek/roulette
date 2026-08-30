import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'roulette_style.dart';
import 'roulette_group.dart';
import 'roulette_unit.dart';
import '../utils/transform_entry.dart';
import '../utils/text.dart';

/// Animated roulette core
class RoulettePaint extends StatelessWidget {
  const RoulettePaint({
    Key? key,
    required this.style,
    required this.group,
    required this.rotation,
    required this.imageInfos,
  }) : super(key: key);

  final RouletteStyle style;
  final RouletteGroup group;
  final double rotation;
  final Map<int, ImageInfo> imageInfos;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.0,
      child: CustomPaint(
        painter: _RoulettePainter(
          rotate: rotation,
          style: style,
          group: group,
          imageInfos: imageInfos,
        ),
      ),
    );
  }
}

class _RoulettePainter extends CustomPainter {
  _RoulettePainter({
    required this.style,
    required this.rotate,
    required this.group,
    required this.imageInfos,
  });

  final double rotate;
  final RouletteStyle style;
  final RouletteGroup group;
  final Map<int, ImageInfo> imageInfos;

  final Paint _paint = Paint();

  // Supersampling cache: the whole wheel is rendered once into a higher
  // resolution offscreen image and then drawn downscaled. Downscaling averages
  // the extra samples, which removes the jagged edges produced by the
  // backend's lack of MSAA (notably on Linux).
  //
  // The buffer is sized to the actual wheel (x _kSupersample, capped) rather
  // than a fixed 2048², so the per-frame downscale stays cheap on the web.
  static const double _kSupersample = 1.0;
  static const double _kMaxResolution = 1024;
  static ui.Image? _cachedImage;
  static double? _cacheResolution;
  static RouletteGroup? _cacheGroup;
  static RouletteStyle? _cacheStyle;
  static Map<int, ImageInfo>? _cacheImages;

  @override
  bool shouldRepaint(covariant _RoulettePainter oldDelegate) {
    return oldDelegate.rotate != rotate ||
        oldDelegate.group != group ||
        oldDelegate.style != style ||
        !mapEquals(oldDelegate.imageInfos, imageInfos);
  }

  /// Renders the full (static) wheel into a high resolution offscreen image.
  ui.Image _renderWheel(double resolution) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final radius = resolution / 2;
    final rect = Rect.fromCircle(
      center: Offset.zero,
      radius: radius,
    );

    canvas.translate(radius, radius);

    canvas.save();
    canvas.rotate(-pi / 2);
    // Draws the backgrounds of the sections.
    _drawBackground(canvas, radius, rect);
    // Draws the content of the sections.
    _drawSections(canvas, radius);
    canvas.restore();

    _drawCenterSticker(canvas, radius);

    final picture = recorder.endRecording();
    return picture.toImageSync(resolution.toInt(), resolution.toInt());
  }

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final resolution =
        (size.width * _kSupersample).clamp(64, _kMaxResolution).toDouble();

    if (_cachedImage == null ||
        _cacheResolution != resolution ||
        !identical(_cacheGroup, group) ||
        !identical(_cacheStyle, style) ||
        !mapEquals(_cacheImages, imageInfos)) {
      _cachedImage?.dispose();
      _cachedImage = _renderWheel(resolution);
      _cacheResolution = resolution;
      _cacheGroup = group;
      _cacheStyle = style;
      _cacheImages = imageInfos;
    }

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(rotate);

    canvas.drawImageRect(
      _cachedImage!,
      Rect.fromLTWH(0, 0, resolution, resolution),
      Rect.fromCircle(center: Offset.zero, radius: radius),
      Paint()..filterQuality = FilterQuality.medium,
    );

    canvas.restore();
  }

  /// Draws the background of the sections.
  ///
  /// If an image is set, also draws a background image.
  void _drawBackground(Canvas canvas, double radius, Rect rect) {
    _paint.strokeWidth = 0;
    _paint.style = ui.PaintingStyle.fill;

    double drewSweep = 0;
    final List<double> boundaries = [0.0];

    for (var i = 0; i < group.divide; i++) {
      final RouletteUnit unit = group.units[i];
      final double sweep = 2 * pi * unit.weight / group.totalWeights;

      canvas.save();
      canvas.rotate(drewSweep);

      // Draws the section background color.
      _paint.color = unit.color;
      _paint.strokeWidth = 0;
      _paint.style = ui.PaintingStyle.fill;
      _paint.isAntiAlias = true;
      canvas.drawArc(rect, 0.0 * i, sweep, true, _paint);

      final resolvedImage = imageInfos[i]?.image;
      if (unit.image != null && resolvedImage != null) {
        // Draws the section background image
        _drawBackgroundImage(canvas, radius, rect, unit, sweep, resolvedImage);
      }

      canvas.restore();
      drewSweep += sweep;
      if (i < group.divide - 1) {
        boundaries.add(drewSweep);
      }
    }

    _drawDividers(canvas, radius, rect, boundaries);
  }

  /// Draws the section dividers (outer rim ring and radial spokes) as filled
  /// shapes so the edges are anti-aliased cleanly on every backend.
  void _drawDividers(Canvas canvas, double radius, Rect rect,
      List<double> boundaries) {
    if (style.dividerThickness <= 0) {
      return;
    }

    _paint.color = style.dividerColor;
    _paint.style = ui.PaintingStyle.fill;
    _paint.strokeWidth = 0;
    _paint.isAntiAlias = true;

    // Outer rim ring drawn once as a filled annulus, kept fully INSIDE the
    // wheel radius so it is never clipped by the widget bounds.
    final double outer = radius;
    final double inner = radius - style.dividerThickness;
    final Path ring = Path()
      ..addOval(Rect.fromCircle(center: Offset.zero, radius: outer))
      ..addOval(Rect.fromCircle(center: Offset.zero, radius: inner));
    ring.fillType = PathFillType.evenOdd;
    canvas.drawPath(ring, _paint);

  // Radial spokes drawn once per boundary as constant-width bands so the
  // divider thickness stays uniform from the rim down to the center. Their
  // outer tip meets the rim ring's center, also staying inside the radius.
  final double halfThickness = style.dividerThickness / 2;
  final double spokeLength = radius - style.dividerThickness / 2;
  for (final double angle in boundaries) {
    canvas.save();
    canvas.rotate(angle);
    canvas.drawRect(
      Rect.fromLTWH(0, -halfThickness, spokeLength, style.dividerThickness),
      _paint,
    );
    canvas.restore();
  }
  }

  /// Draws the image to the background of the current section.
  void _drawBackgroundImage(Canvas canvas, double radius, Rect rect,
      RouletteUnit unit, double sweep, ui.Image image) {
    // Draws the section background image

    // Path for this section.
    Path path = Path();
    path.addArc(rect, 0, sweep);
    path.lineTo(0, 0);

    // Rectangle in which the section is.
    var rect2 = path.getBounds();
    final TileMode tileMode;
    final Matrix4 matrix;

    switch (style.sectionImageLayout) {
      case SectionImageLayout.rotatedFit:
        tileMode = TileMode.repeated;
        if (rect2.height > rect2.width) {
          rect2 =
              Rect.fromLTWH(rect2.left, rect2.top, rect2.height, rect2.height);
        } else {
          rect2 =
              Rect.fromLTWH(rect2.left, rect2.top, rect2.width, rect2.width);
        }
        // Calculates size of image in the square.
        double scaleX = (rect2.width / image.width);
        double scaleY = (rect2.height / image.height);

        // Transformation matrix to scale and rotate image in the section.
        matrix = composeMatrixFromOffsets(
          translate: Offset(style.dividerThickness / 2 - 1,
              rect2.top + rect2.height * 4 + style.dividerThickness / 2 + 1),
          scale: (max(scaleX, scaleY)) - 0.002,
          rotation: sweep / 2 + pi / 2,
          anchor: Offset.zero,
        );
        break;

      case SectionImageLayout.boundingBoxFit:
        tileMode = TileMode.clamp;
        // Prevent images from being rendered with repeating patterns.
        // The image now occupies the intended area without being repeated.

        // For use in the clean Matrix
        double scaleX = rect2.width / image.width;
        double scaleY = rect2.height / image.height;
        double scale = max(scaleX, scaleY);

        matrix = Matrix4.identity()
          ..translateByDouble(rect2.left, rect2.top, 0.0, 1.0)
          ..scaleByDouble(scale, scale, scale, 1);
        break;
    }

    // Drawing the TileMap
    canvas.drawPath(
      path,
      Paint()
        ..shader = ImageShader(
          image,
          tileMode,
          tileMode,
          matrix.storage,
          filterQuality: FilterQuality.high,
        )
        ..style = PaintingStyle.fill
        ..strokeWidth = 0,
    );
  }

  /// Draws every section of the roulette with its text or icon.
  ///
  /// The text or the icon is transformed into a drawable paragraph.
  void _drawSections(Canvas canvas, double radius) {
    double drewSweep = 0.0; // Drew sweep angle

    final paragraphStyle = ui.ParagraphStyle(
      textAlign: TextAlign.center,
    );

    for (var i = 0; i < group.divide; i++) {
      // Draws each section with unit
      final unit = group.units[i];
      final sweep = 2 * pi * unit.weight / group.totalWeights;

      canvas.save();
      canvas.rotate(drewSweep + pi / 2 + sweep / 2);

      // The section might have an icon instead of a text.
      final IconData? icon = unit.icon;

      // If there is an icon, it is converted into a string text.
      // Otherwise, the given text is retrieved.
      final String? text =
          icon == null ? unit.text : String.fromCharCode(icon.codePoint);

      // No string text to draw.
      if (text == null) {
        canvas.restore();
        continue;
      }

      final unitTextStyle = unit.textStyle ?? style.textStyle;

      // Gets the text style of the text or the icon.
      final textStyle = icon == null
          ? unitTextStyle
          : unitTextStyle.copyWith(fontFamily: icon.fontFamily);

      // Calculates chord of circle.
      // Scale textLayoutBias outward as more sections are added — the chord
      // is wider near the rim, giving text more room.
      final n = group.divide;
      final effectiveBias = n > 4
          ? (style.textLayoutBias + (0.99 - style.textLayoutBias) * (1 - 4 / n))
              .clamp(style.textLayoutBias, 0.99)
          : style.textLayoutBias;
      final chord = 2 * (radius * effectiveBias) * sin(sweep / 2);

      // Auto-scale font size to fit the chord when text would overflow.
      final baseFontSize =
          style.maxTextFontSize ?? style.textStyle.fontSize ?? 30;
      final effectiveFontSize = baseFontSize * 3.5 > chord
          ? (chord / 3.5).clamp(baseFontSize * 0.3, baseFontSize)
          : baseFontSize;
      final scaledTextStyle = effectiveFontSize != baseFontSize
          ? textStyle.copyWith(fontSize: effectiveFontSize)
          : textStyle;

      // Creates a builder for the paragraph that will be drawn on the canvas.
      final pb = ui.ParagraphBuilder(paragraphStyle)
        ..pushStyle(scaledTextStyle.asUiTextStyle())
        ..addText(text);

      // Creates the paragraph.
      final paragraph = pb.build();
      final layoutWidth = (chord - 2 * style.textPadding).clamp(0.0, chord);
      paragraph.layout(ui.ParagraphConstraints(width: layoutWidth));

      // Draws the paragraph.
      canvas.drawParagraph(
        paragraph,
        Offset(-layoutWidth / 2, -radius * effectiveBias),
      );

      canvas.restore();
      drewSweep += sweep;
    }
  }

  /// Draws a circle in the center of the roulette of the given size in the
  /// roulette's style.
  void _drawCenterSticker(Canvas canvas, double radius) {
    _paint.color = style.centerStickerColor;
    _paint.strokeWidth = 0;
    _paint.style = ui.PaintingStyle.fill;

    canvas.drawCircle(
      Offset.zero,
      radius * style.centerStickSizePercent,
      _paint,
    );
  }
}
