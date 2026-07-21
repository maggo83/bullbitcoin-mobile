// BitSquiggle32 dependency-free Dart core.
// Grug 2-Clause License: do what want; not sue grug.

import 'dart:math' as math;

const int rows = 7;
const int columns = 5;
const int edgeCount = 58;
const int pixelWidth = 16;
const int pixelHeight = 22;
const int maxSmoothBlobs = 82;
const int _mask32 = 0xffffffff;

enum BitSquiggleStyle {
  standard('standard'),
  highContrast('high-contrast'),
  monochrome('monochrome'),
  blackAndWhite('black-and-white');

  const BitSquiggleStyle(this.label);
  final String label;
}

enum BitSquiggleMode {
  leftRight('A|'),
  topBottom('A-'),
  halfTurn('A+'),
  diagonalSlash('A/');

  const BitSquiggleMode(this.label);
  final String label;
}

final class Edge {
  const Edge(this.startRow, this.startColumn, this.endRow, this.endColumn);

  final int startRow;
  final int startColumn;
  final int endRow;
  final int endColumn;

  @override
  bool operator ==(Object other) =>
      other is Edge &&
      startRow == other.startRow &&
      startColumn == other.startColumn &&
      endRow == other.endRow &&
      endColumn == other.endColumn;

  @override
  int get hashCode => Object.hash(startRow, startColumn, endRow, endColumn);

  @override
  String toString() => 'Edge($startRow, $startColumn, $endRow, $endColumn)';
}

final class BitSquiggleColor {
  const BitSquiggleColor({
    required this.lightness,
    required this.chroma,
    required this.hue,
    required this.hex,
  });

  final double lightness;
  final double chroma;
  final double hue;
  final String hex;

  @override
  bool operator ==(Object other) =>
      other is BitSquiggleColor &&
      lightness == other.lightness &&
      chroma == other.chroma &&
      hue == other.hue &&
      hex == other.hex;

  @override
  int get hashCode => Object.hash(lightness, chroma, hue, hex);
}

final class VisualSpec {
  VisualSpec({
    required this.input,
    required this.mixed,
    required List<int> connections,
    required List<List<int>> cells,
    required this.background,
    required this.foreground,
    required this.style,
    required this.preferredMode,
    required this.actualMode,
    required this.fallback,
    required this.luminanceIndex,
    required this.swapped,
  }) : connections = List.unmodifiable(connections),
       cells = List.unmodifiable(
         cells.map((row) => List<int>.unmodifiable(row)),
       );

  final int input;
  final int mixed;
  final List<int> connections;
  final List<List<int>> cells;
  final BitSquiggleColor background;
  final BitSquiggleColor foreground;
  final BitSquiggleStyle style;
  final BitSquiggleMode preferredMode;
  final BitSquiggleMode actualMode;
  final bool fallback;
  final int luminanceIndex;
  final bool swapped;
}

final class PixelGrid {
  PixelGrid({
    required this.width,
    required this.height,
    required List<int> pixels,
    required this.background,
    required this.foreground,
    required this.style,
  }) : pixels = List.unmodifiable(pixels);

  final int width;
  final int height;
  final List<int> pixels;
  final BitSquiggleColor background;
  final BitSquiggleColor foreground;
  final BitSquiggleStyle style;
}

final class SmoothBlob {
  const SmoothBlob(
    this.topRow,
    this.leftColumn,
    this.bottomRow,
    this.rightColumn,
  );

  final int topRow;
  final int leftColumn;
  final int bottomRow;
  final int rightColumn;

  @override
  bool operator ==(Object other) =>
      other is SmoothBlob &&
      topRow == other.topRow &&
      leftColumn == other.leftColumn &&
      bottomRow == other.bottomRow &&
      rightColumn == other.rightColumn;

  @override
  int get hashCode => Object.hash(topRow, leftColumn, bottomRow, rightColumn);

  @override
  String toString() =>
      'SmoothBlob($topRow, $leftColumn, $bottomRow, $rightColumn)';
}

const _templates = <List<String>>[
  [
    "A B C B' A'",
    "D E F E' D'",
    "G H I H' G'",
    "J K L K' J'",
    "M N O N' M'",
    "P Q R Q' P'",
    "S T U T' S'",
  ],
  [
    'A B C D E',
    'F G H I J',
    'K L M N O',
    'P Q R S T',
    "K' L' M' N' O'",
    "F' G' H' I' J'",
    "A' B' C' D' E'",
  ],
  [
    'A B C D E',
    'F G H I J',
    'K L M N O',
    "P Q R Q' P'",
    "O' N' M' L' K'",
    "J' I' H' G' F'",
    "E' D' C' B' A'",
  ],
  [
    'A B C D E',
    'F G H I J',
    "K L M N I'",
    "O P Q M' H'",
    "R S P' L' G'",
    "T R' O' K' F'",
    "E' D' C' B' A'",
  ],
];

final List<Edge> _edges = List.unmodifiable(_createEdges());
final List<List<List<int>>> _modeDefinitions = List.unmodifiable(
  _templates.map(_createModeDefinition),
);

List<Edge> _createEdges() {
  final result = <Edge>[];
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      if (column + 1 < columns) {
        result.add(Edge(row, column, row, column + 1));
      }
      if (row + 1 < rows) {
        result.add(Edge(row, column, row + 1, column));
      }
    }
  }
  return result;
}

List<List<int>> _createModeDefinition(List<String> templateRows) {
  final references = List<String>.filled(rows * columns, '');
  final sources = <String, int>{};
  for (var row = 0; row < rows; row++) {
    final tokens = templateRows[row].split(' ');
    for (var column = 0; column < columns; column++) {
      final token = tokens[column];
      final copied = token.endsWith("'");
      final name = copied ? token.substring(0, token.length - 1) : token;
      references[row * columns + column] = name;
      if (!copied) sources[name] = row * columns + column;
    }
  }

  final classes = <int, List<int>>{};
  for (var index = 0; index < _edges.length; index++) {
    final edge = _edges[index];
    final first =
        sources[references[edge.startRow * columns + edge.startColumn]]!;
    final second = sources[references[edge.endRow * columns + edge.endColumn]]!;
    final key =
        (first < second ? first : second) * 64 +
        (first > second ? first : second);
    (classes[key] ??= <int>[]).add(index);
  }
  final keys = classes.keys.toList()..sort();
  return List.unmodifiable(
    keys.map((key) => List<int>.unmodifiable(classes[key]!)),
  );
}

/// Return the 58 canonical edges in encoding order.
List<Edge> edges() => _edges;

void _validateInput(int input) {
  if (input < 0 || input > _mask32) {
    throw RangeError.range(input, 0, _mask32, 'input');
  }
}

void _validateConnections(List<int> connections) {
  if (connections.length != edgeCount) {
    throw ArgumentError.value(
      connections.length,
      'connections',
      'must contain 58 entries',
    );
  }
  if (connections.any((value) => value != 0 && value != 1)) {
    throw ArgumentError.value(
      connections,
      'connections',
      'must contain only zeroes and ones',
    );
  }
}

/// Return the bijective 32-bit mixer result as an unsigned Dart [int].
int mix32(int input) {
  _validateInput(input);
  var mixed = (input + 0x9e3779b9) & _mask32;
  mixed ^= mixed >> 16;
  mixed = (mixed * 0x85ebca6b) & _mask32;
  mixed ^= mixed >> 13;
  mixed = (mixed * 0xc2b2ae35) & _mask32;
  mixed ^= mixed >> 16;
  return mixed & _mask32;
}

int freeConnectionCount(BitSquiggleMode mode) =>
    _modeDefinitions[mode.index].length;

bool _matchesModeIndex(List<int> connections, int modeIndex) {
  for (final connectionClass in _modeDefinitions[modeIndex]) {
    final expected = connections[connectionClass.first];
    for (final edgeIndex in connectionClass.skip(1)) {
      if (connections[edgeIndex] != expected) return false;
    }
  }
  return true;
}

bool matchesMode(List<int> connections, BitSquiggleMode mode) {
  _validateConnections(connections);
  return _matchesModeIndex(connections, mode.index);
}

List<int> _expand(List<List<int>> definition, List<int> values) {
  final result = List<int>.filled(edgeCount, 0);
  for (var classIndex = 0; classIndex < definition.length; classIndex++) {
    for (final edgeIndex in definition[classIndex]) {
      result[edgeIndex] = values[classIndex];
    }
  }
  return result;
}

List<int> _encodeDefault(int mixed) => _expand(
  _modeDefinitions.first,
  List.generate(32, (index) => (mixed >> (31 - index)) & 1),
);

List<int> _encodeConnections(int mixed, int modeIndex) {
  if (modeIndex == 0) return _encodeDefault(mixed);
  final definition = _modeDefinitions[modeIndex];
  final payload = mixed & 0x3fffffff;
  return _expand(
    definition,
    List.generate(
      definition.length,
      (index) => (payload >> (29 - (index % 30))) & 1,
    ),
  );
}

bool _hasCapacity(int mixed, int modeIndex) {
  final missingBits = 30 - _modeDefinitions[modeIndex].length;
  return missingBits <= 0 || (mixed & ((1 << missingBits) - 1)) == 0;
}

bool _conflictsWithEarlierMode(List<int> connections, int modeIndex) {
  for (var earlier = 0; earlier < modeIndex; earlier++) {
    if (_matchesModeIndex(connections, earlier)) return true;
  }
  return false;
}

List<List<int>> _activeCells(List<int> connections) {
  final cells = List.generate(rows, (_) => List<int>.filled(columns, 0));
  for (var index = 0; index < edgeCount; index++) {
    if (connections[index] == 0) continue;
    final edge = _edges[index];
    cells[edge.startRow][edge.startColumn] = 1;
    cells[edge.endRow][edge.endColumn] = 1;
  }
  return cells;
}

double _clamp01(double value) => value.clamp(0.0, 1.0);

double _srgbEncode(double value) {
  final clamped = _clamp01(value);
  return clamped <= 0.0031308
      ? 12.92 * clamped
      : 1.055 * math.pow(clamped, 1 / 2.4) - 0.055;
}

BitSquiggleColor _makeColor(double lightness, double chroma, double hue) {
  final radians = hue * math.pi / 180;
  final a = chroma * math.cos(radians);
  final b = chroma * math.sin(radians);
  final l = lightness + 0.3963377774 * a + 0.2158037573 * b;
  final m = lightness - 0.1055613458 * a - 0.0638541728 * b;
  final s = lightness - 0.0894841775 * a - 1.2914855480 * b;
  final l3 = l * l * l;
  final m3 = m * m * m;
  final s3 = s * s * s;
  final red = _srgbEncode(
    4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
  );
  final green = _srgbEncode(
    -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
  );
  final blue = _srgbEncode(
    -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
  );
  String channel(double value) =>
      (value * 255 + 0.5).floor().toRadixString(16).padLeft(2, '0');
  return BitSquiggleColor(
    lightness: lightness,
    chroma: chroma,
    hue: hue,
    hex: '#${channel(red)}${channel(green)}${channel(blue)}',
  );
}

(BitSquiggleColor, BitSquiggleColor) _colors(
  int mixed,
  int input,
  BitSquiggleStyle style,
) {
  final hue = ((mixed >> 12) & 0xf) * 22.5;
  final chroma = 0.05 + ((mixed >> 8) & 0xf) * (0.2 / 15);
  final baseLightness = 0.5 + (mixed & 0x3) * (0.2 / 3);
  var foregroundLightness = baseLightness;
  var backgroundLightness = foregroundLightness - 0.5;
  var foregroundChroma = chroma;
  var backgroundChroma = chroma;
  if (style != BitSquiggleStyle.standard) {
    foregroundLightness = style == BitSquiggleStyle.blackAndWhite
        ? 1
        : baseLightness + 0.3;
    backgroundLightness = style == BitSquiggleStyle.blackAndWhite
        ? 0
        : foregroundLightness - 0.8;
    foregroundChroma =
        style == BitSquiggleStyle.monochrome ||
            style == BitSquiggleStyle.blackAndWhite
        ? 0
        : chroma + 0.1;
    backgroundChroma = foregroundChroma;
  }
  foregroundLightness = _clamp01(foregroundLightness);
  backgroundLightness = _clamp01(backgroundLightness);
  if (_popcount(input).isOdd) {
    final temporary = foregroundLightness;
    foregroundLightness = backgroundLightness;
    backgroundLightness = temporary;
  }
  return (
    _makeColor(backgroundLightness, backgroundChroma, (hue + 180) % 360),
    _makeColor(foregroundLightness, foregroundChroma, hue),
  );
}

int _popcount(int value) {
  var count = 0;
  while (value != 0) {
    value &= value - 1;
    count++;
  }
  return count;
}

/// Derive the canonical immutable visual specification.
VisualSpec spec(
  int input, [
  BitSquiggleStyle style = BitSquiggleStyle.standard,
]) {
  final mixed = mix32(input);
  final preferredModeIndex = mixed >> 30;
  final candidate = _encodeConnections(mixed, preferredModeIndex);
  final fallback =
      preferredModeIndex != 0 &&
      (!_hasCapacity(mixed, preferredModeIndex) ||
          _conflictsWithEarlierMode(candidate, preferredModeIndex));
  final actualModeIndex = fallback ? 0 : preferredModeIndex;
  final connections = fallback ? _encodeDefault(mixed) : candidate;
  final (background, foreground) = _colors(mixed, input, style);
  return VisualSpec(
    input: input,
    mixed: mixed,
    connections: connections,
    cells: _activeCells(connections),
    background: background,
    foreground: foreground,
    style: style,
    preferredMode: BitSquiggleMode.values[preferredModeIndex],
    actualMode: BitSquiggleMode.values[actualModeIndex],
    fallback: fallback,
    luminanceIndex: mixed & 0x3,
    swapped: _popcount(input).isOdd,
  );
}

List<int> _generatePixels(List<int> connections) {
  final raster = List<int>.filled(pixelWidth * pixelHeight, 0);
  final cells = _activeCells(connections);
  void setPixel(int x, int y) => raster[y * pixelWidth + x] = 1;
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      if (cells[row][column] == 0) continue;
      final x = 1 + column * 3;
      final y = 1 + row * 3;
      setPixel(x, y);
      setPixel(x + 1, y);
      setPixel(x, y + 1);
      setPixel(x + 1, y + 1);
    }
  }
  for (var index = 0; index < edgeCount; index++) {
    if (connections[index] == 0) continue;
    final edge = _edges[index];
    final x = 1 + edge.startColumn * 3;
    final y = 1 + edge.startRow * 3;
    if (edge.startRow == edge.endRow) {
      setPixel(x + 2, y);
      setPixel(x + 2, y + 1);
    } else {
      setPixel(x, y + 2);
      setPixel(x + 1, y + 2);
    }
  }
  for (var row = 0; row < rows - 1; row++) {
    for (var column = 0; column < columns - 1; column++) {
      if (connections[_horizontalEdgeIndex(row, column)] == 1 &&
          connections[_horizontalEdgeIndex(row + 1, column)] == 1 &&
          connections[_verticalEdgeIndex(row, column)] == 1 &&
          connections[_verticalEdgeIndex(row, column + 1)] == 1) {
        setPixel(3 + column * 3, 3 + row * 3);
      }
    }
  }
  return raster;
}

/// Derive the exact bordered 16x22 binary raster and its colors.
PixelGrid pixels(
  int input, [
  BitSquiggleStyle style = BitSquiggleStyle.standard,
]) {
  final visual = spec(input, style);
  return PixelGrid(
    width: pixelWidth,
    height: pixelHeight,
    pixels: _generatePixels(visual.connections),
    background: visual.background,
    foreground: visual.foreground,
    style: style,
  );
}

int _horizontalEdgeIndex(int row, int column) => row == rows - 1
    ? row * (2 * columns - 1) + column
    : row * (2 * columns - 1) + 2 * column;

int _verticalEdgeIndex(int row, int column) =>
    row * (2 * columns - 1) +
    (column == columns - 1 ? 2 * columns - 2 : 2 * column + 1);

int _horizontalEdgeBit(int row, int column) =>
    1 << _horizontalEdgeIndex(row, column);

int _verticalEdgeBit(int row, int column) =>
    1 << _verticalEdgeIndex(row, column);

int _junctionBit(int row, int column) => 1 << (row * (columns - 1) + column);

int _requiredEdgeMask(List<int> connections) {
  _validateConnections(connections);
  var result = 0;
  for (var index = 0; index < edgeCount; index++) {
    if (connections[index] == 1) result |= 1 << index;
  }
  return result;
}

int _connectedRectangleEdgeMask(
  int top,
  int left,
  int bottom,
  int right,
  int requiredEdges,
) {
  var result = 0;
  for (var row = top; row <= bottom; row++) {
    for (var column = left; column <= right; column++) {
      if (column < right) {
        final edge = _horizontalEdgeBit(row, column);
        if (requiredEdges & edge == 0) return 0;
        result |= edge;
      }
      if (row < bottom) {
        final edge = _verticalEdgeBit(row, column);
        if (requiredEdges & edge == 0) return 0;
        result |= edge;
      }
    }
  }
  return result;
}

int _requiredJunctionMask(int requiredEdges) {
  var result = 0;
  for (var row = 0; row < rows - 1; row++) {
    for (var column = 0; column < columns - 1; column++) {
      if (_connectedRectangleEdgeMask(
            row,
            column,
            row + 1,
            column + 1,
            requiredEdges,
          ) !=
          0) {
        result |= _junctionBit(row, column);
      }
    }
  }
  return result;
}

int _rectangleJunctionMask(
  int top,
  int left,
  int bottom,
  int right,
  int requiredJunctions,
) {
  var result = 0;
  for (var row = top; row < bottom; row++) {
    for (var column = left; column < right; column++) {
      final junction = _junctionBit(row, column);
      if (requiredJunctions & junction != 0) result |= junction;
    }
  }
  return result;
}

bool _isBetterBlob(
  SmoothBlob candidate,
  SmoothBlob best,
  int newEdges,
  int newJunctions,
  int bestNewEdges,
  int bestNewJunctions,
) {
  final junctionCount = _popcount(newJunctions);
  final bestJunctionCount = _popcount(bestNewJunctions);
  if (junctionCount != bestJunctionCount) {
    return junctionCount > bestJunctionCount;
  }
  final edgeCount = _popcount(newEdges);
  final bestEdgeCount = _popcount(bestNewEdges);
  if (edgeCount != bestEdgeCount) return edgeCount > bestEdgeCount;
  final area =
      (candidate.bottomRow - candidate.topRow + 1) *
      (candidate.rightColumn - candidate.leftColumn + 1);
  final bestArea =
      (best.bottomRow - best.topRow + 1) *
      (best.rightColumn - best.leftColumn + 1);
  if (area != bestArea) return area < bestArea;
  if (candidate.topRow != best.topRow) {
    return candidate.topRow < best.topRow;
  }
  if (candidate.leftColumn != best.leftColumn) {
    return candidate.leftColumn < best.leftColumn;
  }
  if (candidate.bottomRow != best.bottomRow) {
    return candidate.bottomRow < best.bottomRow;
  }
  return candidate.rightColumn < best.rightColumn;
}

int _firstUncovered(int required, int covered, int count) {
  final remaining = required & ~covered;
  for (var index = 0; index < count; index++) {
    if (remaining & (1 << index) != 0) return index;
  }
  return -1;
}

/// Return the ordered canonical rounded-rectangle decomposition.
List<SmoothBlob> smoothBlobs(List<int> connections) {
  final requiredEdges = _requiredEdgeMask(connections);
  final requiredJunctions = _requiredJunctionMask(requiredEdges);
  var coveredEdges = 0;
  var coveredJunctions = 0;
  final result = <SmoothBlob>[];

  while (coveredEdges != requiredEdges ||
      coveredJunctions != requiredJunctions) {
    final anchorEdge = _firstUncovered(requiredEdges, coveredEdges, edgeCount);
    final anchorJunction = anchorEdge < 0
        ? _firstUncovered(
            requiredJunctions,
            coveredJunctions,
            (rows - 1) * (columns - 1),
          )
        : -1;
    late final int anchorTop;
    late final int anchorLeft;
    late final int anchorBottom;
    late final int anchorRight;
    if (anchorEdge >= 0) {
      final edge = _edges[anchorEdge];
      anchorTop = edge.startRow;
      anchorLeft = edge.startColumn;
      anchorBottom = edge.endRow;
      anchorRight = edge.endColumn;
    } else {
      anchorTop = anchorJunction ~/ (columns - 1);
      anchorLeft = anchorJunction % (columns - 1);
      anchorBottom = anchorTop + 1;
      anchorRight = anchorLeft + 1;
    }

    SmoothBlob? best;
    var bestEdges = 0;
    var bestJunctions = 0;
    var leftInclusive = 0;
    for (var top = anchorTop; top >= 0; top--) {
      for (var left = anchorLeft; left >= leftInclusive; left--) {
        var rightExclusive = columns;
        var stopLeftExpansion = false;
        for (var bottom = anchorBottom; bottom < rows; bottom++) {
          for (var right = anchorRight; right < rightExclusive; right++) {
            final candidateEdges = _connectedRectangleEdgeMask(
              top,
              left,
              bottom,
              right,
              requiredEdges,
            );
            if (candidateEdges == 0) {
              if (bottom == anchorBottom && right == anchorRight) {
                leftInclusive = left + 1;
                stopLeftExpansion = true;
              } else {
                rightExclusive = right;
              }
              break;
            }
            final candidateJunctions = _rectangleJunctionMask(
              top,
              left,
              bottom,
              right,
              requiredJunctions,
            );
            final newEdges = candidateEdges & ~coveredEdges;
            final newJunctions = candidateJunctions & ~coveredJunctions;
            if (newEdges == 0 && newJunctions == 0) continue;
            final candidate = SmoothBlob(top, left, bottom, right);
            if (best == null ||
                _isBetterBlob(
                  candidate,
                  best,
                  newEdges,
                  newJunctions,
                  bestEdges & ~coveredEdges,
                  bestJunctions & ~coveredJunctions,
                )) {
              best = candidate;
              bestEdges = candidateEdges;
              bestJunctions = candidateJunctions;
            }
          }
          if (stopLeftExpansion || rightExclusive == anchorRight) break;
        }
        if (stopLeftExpansion) break;
      }
    }
    if (best == null) throw StateError('uncoverable smooth feature');
    result.add(best);
    coveredEdges |= bestEdges;
    coveredJunctions |= bestJunctions;
  }
  return List.unmodifiable(result);
}
