import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/light/color_math.dart';
import 'package:haven/core/light/room_palette.dart' show rgbOf;
import 'package:haven/data/models/device.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/lamp.dart';
import 'package:haven/data/models/lamp_calibration.dart';
import 'package:haven/data/models/snapshot.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven/features/settings/lamp_calibration_screen.dart'
    show lampCalibrationSubtitle;
import 'package:haven/features/settings/lamp_types.dart';

int mired(int k) => (1e6 / k).round();

void main() {
  group('Weißkorrektur', () {
    test('ohne Stützpunkte bleibt alles, wie es ist', () {
      const c = LampCalibration.none;
      expect(c.isIdentity, isTrue);
      for (final k in [1800, 2700, 4000, 6500]) {
        expect(c.mapKelvin(k), k);
      }
      // Stützpunkt mit gleichem Wert zählt nicht als Korrektur.
      expect(const LampCalibration(white: {2700: 2700}).correctsWhite, isFalse);
    });

    test('Stützpunkte treffen genau, dazwischen linear in Mired', () {
      const c = LampCalibration(white: {2700: 3200, 4000: 4400, 6500: 6500});
      expect(c.mapKelvin(2700), 3200);
      expect(c.mapKelvin(4000), 4400);
      expect(c.mapKelvin(6500), 6500);
      // Mitte zwischen 2700 K und 4000 K in Mired.
      final mid = (1e6 / ((1e6 / 2700 + 1e6 / 4000) / 2)).round();
      final shown = c.mapKelvin(mid);
      expect(mired(shown), closeTo((mired(3200) + mired(4400)) / 2, 1.5));
      // Monoton: kälter gemeldet bleibt kälter angezeigt.
      var last = 0;
      for (var k = 2000; k <= 6500; k += 100) {
        final s = c.mapKelvin(k);
        expect(s, greaterThanOrEqualTo(last));
        last = s;
      }
    });

    test('außerhalb der Stützpunkte gilt der Abstand des äußersten', () {
      const c = LampCalibration(white: {2700: 3200});
      final offset = mired(3200) - mired(2700);
      expect(mired(c.mapKelvin(2200)), closeTo(mired(2200) + offset, 1.5));
      expect(mired(c.mapKelvin(4000)), closeTo(mired(4000) + offset, 1.5));
      // Geklemmt auf höchstens 12000 K.
      expect(c.mapKelvin(9000), lessThanOrEqualTo(12000));
    });
  });

  test('Ein Stützpunkt ändern hält die übrigen des Typs fest', () {
    final c = LampCalibration.none.withWhite(
      2700,
      3400,
      anchors: calibrationAnchors,
    );
    expect(c.white, {2700: 3400, 4000: 4000, 6500: 6500});
    expect(c.mapKelvin(4000), 4000);
    expect(c.mapKelvin(6500), 6500);
    expect(c.mapKelvin(2700), 3400);
    // Die festen Punkte bleiben auch nach dem Speichern.
    expect(LampCalibration.fromJson(c.toJson()), c);
    // Alles wieder auf Anfang: keine Korrektur mehr.
    expect(c.withWhite(2700, 2700).isIdentity, isTrue);
  });

  group('Helligkeit', () {
    test('Verstärkung und Kurve', () {
      expect(LampCalibration.none.mapLevel(0.5), 0.5);
      expect(LampCalibration.none.mapLevel(0), 0);
      const c = LampCalibration(gain: 0.8, gamma: 2);
      expect(c.mapLevel(0.5), closeTo(0.2, 1e-9));
      expect(c.mapLevel(1), closeTo(0.8, 1e-9));
      // Heller als 100 % geht bis maxShownLevel.
      const hot = LampCalibration(gain: 1.5, gamma: 0.5);
      expect(hot.mapLevel(1), maxShownLevel);
      expect(hot.mapLevel(0.25), closeTo(0.75, 1e-9));
      expect(shownPercent(c, 50), 20);
    });
  });

  group('JSON', () {
    test('Hin und zurück, Unsinn wird übergangen', () {
      const c = LampCalibration(
        white: {2700: 3100, 6500: 6000},
        gain: 0.85,
        gamma: 1.3,
      );
      final all = const LampCalibrations().withModel('Tuya|TS0505B_hs', c);
      final back = LampCalibrations.fromJson(all.toJson());
      expect(back, all);
      expect(back.byModel['Tuya|TS0505B_hs'], c);

      final odd = LampCalibration.fromJson({
        'white': [
          [2700, 3000],
          ['x', 1],
          [2700],
          [50, 3000],
        ],
        'gain': 9,
        'gamma': 'hoch',
      });
      expect(odd.white, {2700: 3000});
      expect(odd.gain, LampCalibration.maxGain);
      expect(odd.gamma, 1);
      expect(LampCalibrations.fromJson('kaputt'), LampCalibrations.empty);
    });

    test('Ohne Korrektur fällt der Typ heraus', () {
      final all = const LampCalibrations()
          .withModel('a|1', const LampCalibration(gain: 0.5))
          .withModel('a|1', LampCalibration.none);
      expect(all.byModel, isEmpty);
      expect(all.isEmpty, isTrue);
      expect(all.toJson(), isEmpty);
    });
  });

  group('Lampentypen', () {
    test('Zigbee-Modell schlägt das HA-Register', () {
      final m = lampModelsOf(
        devices: const [
          HavenDevice(
            id: 'd1',
            name: 'Lampe Decke Salon',
            entityIds: ['light.lampe_decke_salon', 'update.lampe_decke_salon'],
            manufacturer: 'Tuya',
            model: 'Smart LED bulb (RGBCW)',
          ),
          HavenDevice(
            id: 'd2',
            name: 'Stehlampe',
            entityIds: ['light.stehlampe'],
            manufacturer: 'Beispiel AG',
            model: 'WLAN 7',
          ),
          HavenDevice(id: 'd3', name: 'Ohne', entityIds: ['light.ohne']),
        ],
        zigbee: const [
          ZbDevice(
            ieee: '0x1',
            friendlyName: 'Lampe Decke Salon',
            vendor: 'Tuya',
            model: 'TS0505B_hs',
            haEntities: ['light.lampe_decke_salon'],
          ),
        ],
      );
      expect(
        m.keys,
        unorderedEquals(['light.lampe_decke_salon', 'light.stehlampe']),
      );
      expect(m['light.lampe_decke_salon']!.key, 'Tuya|TS0505B_hs');
      expect(m['light.stehlampe']!.label, 'Beispiel AG WLAN 7');
    });

    test('Entwicklungsdaten: mehrere Modelle, häufigstes zuerst', () async {
      final repo = FakeRepository(simulate: false);
      await repo.start();
      final types = lampTypesOf(repo.snapshot);
      expect(types.length, greaterThanOrEqualTo(2));
      expect(types.first.key, 'Tuya|TS0505B_hs');
      expect(types.first.lamps, hasLength(3));
      final dimmer = types.firstWhere(
        (t) => t.model.model == 'YSR-MINI-01_dimmer',
      );
      expect(dimmer.hasKelvin, isFalse);
      expect(dimmer.anchors, [assumedWhiteKelvin]);
      expect(types.first.anchors, calibrationAnchors);
      expect(
        lampCalibrationSubtitle(types, repo.snapshot.lampCalibration),
        '${types.length} Lampentypen',
      );
      await repo.dispose();
    });
  });

  group('Anzeige der Lampen', () {
    EntityState white({String mode = 'color_temp'}) =>
        EntityState('light.decke', 'on', {
          'supported_color_modes': ['color_temp', 'hs'],
          'color_mode': mode,
          'brightness': 128,
          'color_temp_kelvin': mode == 'color_temp' ? 2700 : null,
          // HA meldet im Weißmodus auch eine RGB-Farbe.
          'rgb_color': mode == 'color_temp' ? [255, 167, 87] : [40, 90, 255],
        });
    const warmer = LampCalibration(white: {2700: 3600}, gain: 0.5, gamma: 1);

    test('Weißmodus: angezeigt wird der korrigierte Weißton', () {
      final raw = Lamp.fromEntity(white());
      expect(raw.displayColor, raw.color);
      expect(raw.displayLevel, closeTo(0.5, 0.01));
      final l = Lamp.fromEntity(white(), calibration: warmer);
      // Regler arbeiten weiter mit den gemeldeten Werten.
      expect(l.kelvin, 2700);
      expect(l.brightness, raw.brightness);
      expect(l.displayColor, kelvinToRgb(3600));
      expect(l.displayLevel, closeTo(0.25, 0.01));
      expect(l == raw, isFalse);
    });

    test('Farbmodus: Farbe bleibt, nur die Helligkeit wirkt', () {
      final l = Lamp.fromEntity(white(mode: 'hs'), calibration: warmer);
      expect(l.isWhite, isFalse);
      expect(l.displayColor, (40, 90, 255));
      expect(l.displayLevel, closeTo(0.25, 0.01));
    });

    test('Lampe ohne Farbtemperatur: feste Lichtfarbe wird korrigiert', () {
      final l = Lamp.fromEntity(
        const EntityState('light.dimmer', 'on', {
          'supported_color_modes': ['brightness'],
          'brightness': 255,
        }),
        calibration: const LampCalibration(white: {2700: 2200}),
      );
      expect(l.isWhite, isTrue);
      expect(l.displayColor, kelvinToRgb(2200));
    });

    test('Snapshot und 3D-Karte nehmen die Korrektur des Typs', () {
      const model = LampModel(vendor: 'Tuya', model: 'TS0505B_hs');
      final snap = HavenSnapshot(
        entities: {'light.decke': white()},
        lampModels: const {'light.decke': model},
        lampCalibration: const LampCalibrations().withModel(
          model.key,
          const LampCalibration(white: {2700: 3600}, gain: 1.4, gamma: 0.5),
        ),
      );
      final l = snap.lamp('light.decke')!;
      expect(l.displayColor, kelvinToRgb(3600));
      final s = lampStateOf(l);
      final (r, g, b) = kelvinToRgb(3600);
      expect(rgbOf(s.color), (r, g, b));
      // Heller als 100 % ist erlaubt (Lampe wirkt heller als andere).
      expect(s.brightness, greaterThan(0.9));
      // Ohne Typ: keine Korrektur.
      final plain = HavenSnapshot(entities: {'light.decke': white()});
      expect(plain.lamp('light.decke')!.displayColor, l.color);
    });
  });
}
