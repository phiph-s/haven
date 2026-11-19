import 'dart:ui' show SemanticsAction, SemanticsActionEvent;

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
              width: ThermoEdge.width,
              height: 176,
              child: ThermoEdge(
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

  testWidgets('Zeigt Ist und Ziel, Ziehen nach oben erhöht in halben Grad', (
    tester,
  ) async {
    final sent = await pump(tester);
    expect(find.text('19,5'), findsOneWidget);
    expect(find.text('20,0°'), findsOneWidget);
    // Skala 15–26 °C: ein halbes Grad je (176 - 18) / 22 ≈ 7,2 px.
    await tester.drag(find.byType(ThermoEdge), const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 10));
    expect(sent, hasLength(1));
    expect(sent.single, greaterThan(20));
    expect(sent.single * 2, (sent.single * 2).roundToDouble());
    expect(
      find.text('${sent.single.toStringAsFixed(1).replaceAll('.', ',')}°'),
      findsOneWidget,
    );
  });

  testWidgets('Mausrad: ein halbes Grad je Raststufe, nach oben wärmer', (
    tester,
  ) async {
    final sent = await pump(tester);
    final center = tester.getCenter(find.byType(ThermoEdge));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
    await tester.pump();
    expect(find.text('21,0°'), findsOneWidget);
    // Gesendet wird erst, wenn das Rad ruht.
    expect(sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 700));
    expect(sent, [21.0]);
  });

  testWidgets('Bedienhilfe: Schieberegler mit Erhöhen und Verringern', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final sent = await pump(tester, target: 21);
    final node = tester.getSemantics(find.byType(ThermoEdge));
    expect(node.label, contains('Zieltemperatur Salon'));
    expect(node.value, '21,0 Grad');
    tester.binding.performSemanticsAction(
      SemanticsActionEvent(
        type: SemanticsAction.increase,
        nodeId: node.id,
        viewId: tester.view.viewId,
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(sent, [21.5]);
    handle.dispose();
  });
}
