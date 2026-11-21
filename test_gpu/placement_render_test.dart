// Möbel und Geräte in 3D platzieren: rendert den Editor mit echter GPU und
// echter Schrift (Handy und Desktop) nach build/gpu/placement_*.png bzw.
// nach PLACEMENT_OUT, wenn gesetzt (Sichtprüfung).
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/placement_render_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/furniture_library.dart';
import 'package:haven/features/map/map_markers.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:haven_3d/haven_3d.dart' show Scene3DSupport;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo implements FloorPlanRepository {
  _Repo(this.plan);
  HavenFloorPlan? plan;
  @override
  Future<HavenFloorPlan?> load() async => plan;
  @override
  Future<void> save(HavenFloorPlan p) async => plan = p;
  @override
  Future<void> clear() async => plan = null;
}

final String _out =
    Platform.environment['PLACEMENT_OUT'] ?? 'build/gpu/placement';

Future<void> _fonts(WidgetTester tester) => tester.runAsync(() async {
  final dir =
      '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
      '/bin/cache/artifacts/material_fonts';
  if (!Directory(dir).existsSync()) return;
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final b = File('$dir/$f').readAsBytesSync();
      l.addFont(Future.value(ByteData.sublistView(b)));
    }
    await l.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  // Texte ohne Schriftfamilie (z. B. im Segment-Schalter) auch in Roboto.
  await load('FlutterTest', ['Roboto-Medium.ttf']);
});

Future<void> _frames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _save(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });

/// Editor unter [location] öffnen, [act] spielt Gesten, danach ein Bild.
Future<void> _shot(
  WidgetTester tester,
  String name,
  String location, {
  Size size = const Size(412, 915),
  String theme = 'light',
  Future<void> Function(WidgetTester tester)? act,
}) async {
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({'theme_mode': theme});
  final store = SettingsStore(await SharedPreferences.getInstance());
  late Session session;
  await tester.runAsync(() async {
    final r = FakeRepository(simulate: false);
    await r.start();
    session = Session(SessionMode.fake, r);
  });
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(session),
      floorPlanRepositoryProvider.overrideWithValue(_Repo(kFakeFloorPlan)),
    ],
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: HavenApp(initialLocation: location),
      ),
    ),
  );
  await _frames(tester, 50);
  if (act != null) {
    await act(tester);
    await _frames(tester, 30);
  }
  await _save(tester, key, name);
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 3));
  }
}

/// Bildschirmpunkt (global) eines Punkts in Zellen auf Höhe [z] (Meter).
Offset _at(WidgetTester tester, Offset cells, {double z = 0}) {
  final view = find.byType(h3.Scene3DView);
  final cam = tester.widget<h3.Scene3DView>(view).controller.camera;
  final m = kFakeFloorPlan.grid.cellMeters;
  final p = cam.project(
    h3.V3(cells.dx * m, cells.dy * m, z),
    tester.getSize(view),
  );
  return tester.getTopLeft(view) + p.offset;
}

Finder _tile(String id) =>
    find.byWidgetPredicate((w) => w is LibraryTile && w.type.id == id);

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('Platzieren in 3D', (tester) async {
    addTearDown(tester.view.reset);
    await _fonts(tester);
    const desk = Size(1440, 900);
    // Gewähltes Sofa: Grundfläche, Drehring, Werkzeuge.
    await _shot(
      tester,
      'select_phone',
      '/map/editor?mode=furniture&view=3d&sel=salon&fsel=sofa',
    );
    // Neuer Schrank: folgt dem Finger, rastet mit dem Rücken an die Wand.
    await _shot(
      tester,
      'place_phone',
      '/map/editor?mode=furniture&view=3d',
      act: (tester) async {
        await tester.tap(find.text('Schlafen'));
        await _frames(tester, 4);
        await tester.tap(_tile('wardrobe'));
        await _frames(tester, 4);
        final g = await tester.startGesture(_at(tester, const Offset(9, 9)));
        for (var i = 1; i <= 10; i++) {
          await g.moveTo(
            Offset.lerp(
              _at(tester, const Offset(9, 9)),
              _at(tester, const Offset(8, 4.2)),
              i / 10,
            )!,
          );
          await _frames(tester, 1);
        }
        await g.up();
      },
    );
    await _shot(
      tester,
      'place_dark_phone',
      '/map/editor?mode=furniture&view=3d',
      theme: 'dark',
      act: (tester) async {
        await tester.tap(_tile('armchair'));
        await _frames(tester, 4);
        await tester.tapAt(_at(tester, const Offset(13, 12)));
        await _frames(tester, 2);
      },
    );
    await _shot(
      tester,
      'select_desktop',
      '/map/editor?mode=furniture&view=3d&fsel=bed',
      size: desk,
    );
    await _shot(
      tester,
      'place_desktop',
      '/map/editor?mode=furniture&view=3d',
      size: desk,
      act: (tester) async {
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: _at(tester, const Offset(14, 5)));
        await tester.tap(_tile('sofa'));
        await _frames(tester, 2);
        await mouse.moveTo(_at(tester, const Offset(12, 12)));
        await _frames(tester, 2);
        await mouse.moveTo(_at(tester, const Offset(9, 13.4)));
        await _frames(tester, 2);
      },
    );
    // Gerät auf die Wand ziehen (Momentaufnahme mitten im Ziehen).
    await _shot(
      tester,
      'device_wall_desktop',
      '/map/editor?mode=devices',
      size: desk,
      act: (tester) async {
        final marker = find.byWidgetPredicate(
          (w) =>
              w is MapMarker &&
              w.entityId == 'binary_sensor.bewegungsmelder_salon_occupancy',
        );
        final from = tester.getCenter(marker);
        final to = _at(tester, const Offset(8.2, 3.4), z: 1.5);
        final g = await tester.startGesture(from);
        for (var i = 1; i <= 12; i++) {
          await g.moveTo(Offset.lerp(from, to, i / 12)!);
          await _frames(tester, 1);
        }
        await _frames(tester, 10);
        _pending = g;
      },
    );
    await _pending?.up();
    _pending = null;
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// Geste, die erst nach dem Bild losgelassen wird.
TestGesture? _pending;
