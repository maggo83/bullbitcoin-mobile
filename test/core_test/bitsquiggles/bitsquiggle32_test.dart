import 'package:bb_mobile/core/bitsquiggles/bitsquiggles_renderer_flutter.dart'
    as bitsquiggles;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches the canonical golden fingerprint', () {
    final visual = bitsquiggles.spec(0x89abcdef);
    final grid = bitsquiggles.pixels(0x89abcdef);

    expect(visual.mixed, 0x47ac5876);
    expect(visual.preferredMode, bitsquiggles.BitSquiggleMode.topBottom);
    expect(visual.actualMode, bitsquiggles.BitSquiggleMode.topBottom);
    expect(visual.fallback, isFalse);
    expect(visual.background.hex, '#140040');
    expect(visual.foreground.hex, '#8d9200');
    expect(grid.width, 16);
    expect(grid.height, 22);
    expect(grid.pixels.length, 352);
  });

  test('falls back to the default mode when required', () {
    final visual = bitsquiggles.spec(0x00000001);

    expect(visual.preferredMode, bitsquiggles.BitSquiggleMode.halfTurn);
    expect(visual.actualMode, bitsquiggles.BitSquiggleMode.leftRight);
    expect(visual.fallback, isTrue);
  });

  testWidgets('smooth view uses the requested badge dimensions', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: bitsquiggles.BitSquiggleView(
            visual: bitsquiggles.spec(
              0x89abcdef,
              bitsquiggles.BitSquiggleStyle.highContrast,
            ),
            width: 32,
            height: 44,
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(CustomPaint)), const Size(32, 44));
  });
}
