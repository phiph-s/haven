import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/theme/theme.dart';
import 'package:haven/features/home/room_render.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  Future<List<double>> pump(WidgetTester tester, {double target = 20}) async {
    final sent = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: havenDarkTheme,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 152,
              height: 112,
              child: TempStepper(
                name: 'Salon',
                climate: TileClimate(
                  current: 19.5,
                  target: target,
                  heating: false,
                  off: false,
                  min: 5,
                  max: 30,
                  label: 'Thermostat',
                  set: (v) async {
                    sent.add(v);
                    return null;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return sent;
  }

  testWidgets(
    'Plus und Minus ändern das Ziel in halben Grad, gesendet wird, wenn die '
    'Bedienung ruht',
    (tester) async {
      final sent = await pump(tester);
      expect(find.text('19,5°'), findsOneWidget);
      expect(find.text('20,0°'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Wärmer'));
      await tester.tap(find.bySemanticsLabel('Wärmer'));
      await tester.tap(find.bySemanticsLabel('Kälter'));
      await tester.pump();
      expect(find.text('20,5°'), findsOneWidget);
      expect(sent, isEmpty);
      await tester.pump(const Duration(milliseconds: 800));
      expect(sent, [20.5]);
      await tester.pump(const Duration(seconds: 7));
    },
  );

  testWidgets('Senkrecht wischen verstellt nichts (Scrollen)', (tester) async {
    final sent = await pump(tester);
    await tester.drag(find.byType(TempStepper), const Offset(0, -60));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('20,0°'), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('Mausrad: ein halbes Grad je Raststufe, nach oben wärmer', (
    tester,
  ) async {
    final sent = await pump(tester);
    final center = tester.getCenter(find.byType(TempStepper));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
    await tester.pump();
    expect(find.text('21,0°'), findsOneWidget);
    expect(sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 800));
    expect(sent, [21.0]);
    await tester.pump(const Duration(seconds: 7));
  });
}
