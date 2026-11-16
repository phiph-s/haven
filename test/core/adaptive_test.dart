import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/adaptive/breakpoints.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('Fensterklassen', () {
    test('Grenzen', () {
      expect(WindowClass.of(0), WindowClass.compact);
      expect(WindowClass.of(412), WindowClass.compact);
      expect(WindowClass.of(599.9), WindowClass.compact);
      expect(WindowClass.of(600), WindowClass.medium);
      expect(WindowClass.of(999), WindowClass.medium);
      expect(WindowClass.of(1000), WindowClass.expanded);
      expect(WindowClass.of(1359), WindowClass.expanded);
      expect(WindowClass.of(1360), WindowClass.large);
      expect(WindowClass.of(2560), WindowClass.large);
    });

    test('Desktop erst ab 1000 px', () {
      expect(WindowClass.compact.isDesktop, isFalse);
      expect(WindowClass.medium.isDesktop, isFalse);
      expect(WindowClass.expanded.isDesktop, isTrue);
      expect(WindowClass.large.isDesktop, isTrue);
    });

    test('Spalten im Raster', () {
      expect(gridColumns(0, minItem: 236), 1);
      expect(gridColumns(230, minItem: 236), 1);
      expect(gridColumns(484, minItem: 236), 2);
      expect(gridColumns(760, minItem: 236), 3);
      expect(gridColumns(5000, minItem: 236, max: 5), 5);
    });
  });

  testWidgets('Kontext: Desktop-Layout, Rand unten, AdaptiveLayout', (
    tester,
  ) async {
    Future<(bool, double, String)> probe(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      late bool desktop;
      late double clearance;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(size: size),
            child: Builder(
              builder: (context) {
                desktop = context.isDesktopLayout;
                clearance = context.navClearance;
                return AdaptiveLayout(
                  compact: (_) => const Text('Handy'),
                  desktop: (_) => const Text('Desktop'),
                );
              },
            ),
          ),
        ),
      );
      final text = find.byType(Text).evaluate().single.widget as Text;
      return (desktop, clearance, text.data!);
    }

    addTearDown(tester.view.reset);
    expect(await probe(const Size(412, 915)), (false, 120.0, 'Handy'));
    expect(await probe(const Size(1440, 900)), (true, 28.0, 'Desktop'));
  });
}
