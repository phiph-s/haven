import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/widgets/horizontal_scroller.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late ScrollController inner;
  final outer = ScrollController();

  Future<void> pump(WidgetTester tester, {bool mouseDrag = true}) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListView(
          controller: outer,
          children: [
            SizedBox(
              height: 100,
              child: HorizontalScroller(
                mouseDrag: mouseDrag,
                builder: (context, c) {
                  inner = c;
                  return ListView(
                    controller: c,
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < 20; i++)
                        const SizedBox(width: 100, height: 100),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 2000),
          ],
        ),
      ),
    );
  }

  Future<void> wheel(WidgetTester tester, double dy) async {
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(p.hover(const Offset(50, 50)));
    await tester.sendEventToBinding(p.scroll(Offset(0, dy)));
    await tester.pump();
  }

  testWidgets('Mausrad scrollt die horizontale Liste, nicht die Seite', (
    tester,
  ) async {
    await pump(tester);
    await wheel(tester, 120);
    expect(inner.offset, 120);
    expect(outer.offset, 0);
  });

  testWidgets('am Ende der Liste scrollt das Rad wieder die Seite', (
    tester,
  ) async {
    await pump(tester);
    inner.jumpTo(inner.position.maxScrollExtent);
    await wheel(tester, 120);
    expect(outer.offset, greaterThan(0));
    // Nach oben am Anfang ebenso.
    inner.jumpTo(0);
    outer.jumpTo(0);
    await wheel(tester, -50);
    expect(inner.offset, 0);
  });

  testWidgets('Ziehen mit der Maus nur mit mouseDrag', (tester) async {
    await pump(tester);
    await tester.dragFrom(
      const Offset(300, 50),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(inner.offset, greaterThan(100));

    await pump(tester, mouseDrag: false);
    inner.jumpTo(0);
    await tester.dragFrom(
      const Offset(300, 50),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(inner.offset, 0);
  });
}
