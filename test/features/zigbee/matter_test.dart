import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/device.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/device_pool.dart';

void main() {
  test('Protokoll aus haven/rooms: Matter, Z-Wave, Zigbee über IEEE', () {
    HavenDevice d(Map<String, dynamic> extra) =>
        HavenDevice.fromJson({'device_id': 'd', 'name': 'D', ...extra});
    final m = d({'protocol': 'matter', 'sw_version': '1.2'});
    expect(m.protocol, DeviceProtocol.matter);
    expect(m.isMatter, isTrue);
    expect(m.swVersion, '1.2');
    expect(d({'protocol': 'zwave'}).protocol, DeviceProtocol.zwave);
    expect(d({'ieee': '0x1'}).protocol, DeviceProtocol.zigbee);
    expect(d({}).protocol, isNull, reason: 'WLAN, Cloud, alte Integration');
  });

  test('Beispieldaten: Matter-Geräte im Pool der Karte', () async {
    final repo = FakeRepository(simulate: false);
    await repo.start();
    addTearDown(repo.dispose);
    final s = repo.snapshot;
    final pool = buildDevicePool(
      s,
      await repo.zigbeeDevices(),
      const HavenFloorPlan(),
    );
    final matter = pool.matter!;
    expect(matter.title, 'Matter-Geräte');
    expect(matter.total, 3);
    final all = matter.groups.expand((g) => g.devices).toList();
    expect(all.every((d) => d.protocol == DeviceProtocol.matter), isTrue);
    final lamp = all.firstWhere((d) => d.name == 'Stehleuchte Diele');
    expect(lamp.mainEntityId, 'light.stehleuchte_diele');
    expect(lamp.kind, FloorKind.light);
    expect(lamp.areaId, 'diele');
    // Zigbee-Geräte stehen nicht doppelt (bei Matter oder „Weitere“).
    expect(pool.other.total, 0);
    expect(
      pool.zigbee.groups.first.devices.first.protocol,
      DeviceProtocol.zigbee,
    );
  });
}
