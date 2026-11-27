import '../data/models/room.dart';
import '../data/scene_look.dart';
import '../data/scene_styles.dart';

/// Baut die Räume der Beispielwohnung aus den Konstanten in `fake_data.dart`.
/// Jedes Gerät und jede Gruppe nennt seinen Raum selbst (`room`), es wird
/// nichts aus Namen geraten.
class FakeRooms {
  FakeRooms(this.inventory);

  final Map<String, dynamic> inventory;

  List<Map<String, dynamic>> get _devices => [
    for (final d in inventory['z2m_devices'] as List) d as Map<String, dynamic>,
  ];
  List<Map<String, dynamic>> get _groups => [
    for (final g in inventory['z2m_groups'] as List) g as Map<String, dynamic>,
  ];

  /// Raum-ID eines Geräts oder `null`.
  String? roomOfDevice(String friendlyName) {
    for (final d in _devices) {
      if (d['friendly_name'] == friendlyName) return d['room'] as String?;
    }
    return null;
  }

  /// [scenes] ersetzt die Szenen der Gruppen (Gruppen-ID → `[{id, name,
  /// look, sync, checked_at}]`), damit das Fake Szenen anlegen und ändern kann.
  List<Room> derive({Map<int, List<Map<String, dynamic>>>? scenes}) {
    final rooms = <Room>[];
    for (final r in inventory['rooms'] as List) {
      final id = r['id'] as String;
      final devs = _devices.where((d) => d['room'] == id).toList();
      final lights = <String>[];
      for (final d in devs) {
        if (d['device_type'] != 'light') continue;
        final ents = (d['entities'] as Map).keys.cast<String>();
        lights.addAll(ents.where((e) => e.startsWith('light.')));
      }
      // Matter-Lampen sind in keiner Zigbee-Gruppe: Zusatzgeräte für Szenen
      final outside = <String>[];
      for (final d in (inventory['matter_devices'] as List? ?? const [])) {
        if (d['room'] != id || d['device_type'] != 'light') continue;
        final ents = (d['entities'] as Map).keys.cast<String>();
        lights.addAll(ents.where((e) => e.startsWith('light.')));
        outside.addAll(ents.where((e) => e.startsWith('light.')));
      }
      final switches = [
        for (final d in devs)
          // Einstell-Schalter von Thermostaten sind in HA Konfiguration
          if (!'${d['friendly_name']}'.contains(
            RegExp('thermostat|display', caseSensitive: false),
          ))
            ...(d['entities'] as Map).keys.cast<String>().where(
              (e) => e.startsWith('switch.'),
            ),
      ];

      // Klimasensor: bevorzugt „Sensor …“, sonst irgendein Gerät mit Werten.
      String? temp;
      String? hum;
      final withTemp =
          devs
              .where(
                (d) => (d['entities'] as Map).keys.any(
                  (e) => (e as String).endsWith('_temperature'),
                ),
              )
              .toList()
            ..sort((a, b) {
              int rank(Map<String, dynamic> d) =>
                  (d['friendly_name'] as String).startsWith('Sensor ') ? 0 : 1;
              return rank(a).compareTo(rank(b));
            });
      if (withTemp.isNotEmpty) {
        final ents = (withTemp.first['entities'] as Map).keys.cast<String>();
        temp = ents.firstWhere((e) => e.endsWith('_temperature'));
        for (final e in ents) {
          if (e.endsWith('_humidity')) hum = e;
        }
      }

      final controls = <RoomControl>[
        for (final d in devs)
          if (d['device_type'] == 'knob' || d['device_type'] == 'remote')
            RoomControl(
              name: d['friendly_name'] as String,
              kind: d['device_type'] == 'knob' ? 'knob' : 'button',
              batteryEntityId: (d['entities'] as Map).keys
                  .cast<String?>()
                  .firstWhere(
                    (e) => e!.endsWith('_battery'),
                    orElse: () => null,
                  ),
            ),
      ];

      // Szenen der Gruppe dieses Raums.
      final roomScenes = <RoomScene>[];
      final missing = <String>[];
      int? groupId;
      for (final g in _groups) {
        if (g['room'] != id) continue;
        final gid = g['id'] as int;
        if (groupId == null) {
          final members = {for (final m in g['members'] as List) '$m'};
          for (final d in devs) {
            if (d['device_type'] != 'light' ||
                members.contains(d['friendly_name'])) {
              continue;
            }
            missing.addAll(
              (d['entities'] as Map).keys.cast<String>().where(
                (e) => e.startsWith('light.'),
              ),
            );
          }
        }
        groupId ??= gid;
        for (final s in (scenes?[gid] ?? (g['scenes'] as List))) {
          final name = s['name'] as String;
          final look = SceneLook.fromJson(s['look']);
          final style = sceneStyleFor(name);
          roomScenes.add(
            RoomScene(
              id: slugify(name),
              name: name,
              colors: look?.cardColors ?? style.colors,
              brightness: look?.brightness ?? style.brightness,
              kelvin: look == null ? style.kelvin : look.kelvin,
              groupId: gid,
              number: s['id'] as int,
              stored: look != null,
              sync: SceneSync.parse(s['sync']),
              checkedAt: DateTime.tryParse('${s['checked_at'] ?? ''}'),
              devices: [
                for (final d in (s['devices'] as List? ?? const [])) '$d',
              ],
              onlyLightIds: look == null && name == 'Lichtleiste'
                  ? lights.where((l) => l.contains('lichtleiste')).toList()
                  : null,
              entityId:
                  'scene.${slugify(g['name'] as String)}_${s['id']}_${slugify(name)}',
            ),
          );
        }
      }

      rooms.add(
        Room(
          id: id,
          name: r['name'] as String,
          lightIds: lights,
          temperatureId: temp,
          humidityId: hum,
          scenes: roomScenes,
          controls: controls,
          zigbeeGroupId: groupId,
          sceneLightIds: groupId == null ? lights : [...outside, ...missing],
          switchIds: switches,
          groupMissingLightIds: missing,
        ),
      );
    }
    return rooms;
  }
}
