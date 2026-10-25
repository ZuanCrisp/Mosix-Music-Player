import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// Renders the [RepaintBoundary] behind [boundaryKey] to a PNG named
/// [fileName] in the temporary directory.
///
/// Returns null when the boundary is not laid out or the image cannot be
/// encoded, so each caller decides how to report that.
Future<File?> captureBoundaryToPngFile(
  GlobalKey boundaryKey, {
  required double pixelRatio,
  required String fileName,
}) async {
  final boundary =
      boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) return null;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final bytes = await image.toByteData(format: ImageByteFormat.png);
  image.dispose();
  if (bytes == null) return null;
  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}/$fileName');
  await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  return file;
}
