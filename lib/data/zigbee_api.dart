import 'models/zigbee.dart';
import 'models/zigbee_network.dart';

/// Zigbee-Teil der Repository-Schnittstelle. Lesen geht über die vorhandenen
/// `haven/zigbee/*`-Befehle der Integration, Schreiben über Befehle, die es
/// dort noch nicht gibt (TODO je Methode, Vorschlag für Name und Payload).
/// Das `FakeRepository` simuliert alles im Speicher.
abstract interface class ZigbeeApi {
  /// `haven/subscribe_zigbee`: Geräte, Gruppen, Info, Zustände und
  /// Bridge-Ereignisse (`device_joined`, `device_interview`, ...).
  Stream<ZbEvent> get zigbeeEvents;

  /// `haven/zigbee/devices`.
  Future<List<ZbDevice>> zigbeeDevices();

  /// `haven/zigbee/device` mit `classified`.
  Future<ZbDevice> zigbeeDevice(String ieee);

  /// `haven/zigbee/groups`.
  Future<List<ZbGroup>> zigbeeGroups();

  /// `haven/info` → `z2m`.
  Future<ZbBridgeInfo> zigbeeInfo();

  /// Letzte bekannte Z2M-Werte je Gerät (IEEE → Property → Wert), z. B.
  /// `linkquality`, `battery`, `sensitivity`. TODO Integration:
  /// `haven/zigbee/state` `{}` → `{"states": {"0x...": {...}}}`. Fehlt der
  /// Befehl, kommt eine leere Map und die App liest Entity-Zustände.
  Future<Map<String, Map<String, dynamic>>> zigbeeStates();

  /// Setzt Z2M-Werte. TODO Integration: `haven/zigbee/set`
  /// `{"ieee": "0x..", "values": {"sensitivity": "high"}}`
  /// (Publish auf `<base>/<name>/set`).
  Future<void> zigbeeSet(String ieee, Map<String, dynamic> values);

  /// TODO Integration: `haven/zigbee/rename`
  /// `{"ieee": "0x..", "name": "Neu", "rename_ha_entities": true}`
  /// (`bridge/request/device/rename`, `homeassistant_rename`).
  Future<void> zigbeeRename(
    String ieee,
    String name, {
    bool renameHaEntities = true,
  });

  /// TODO Integration: `haven/zigbee/set_area`
  /// `{"ieee": "0x..", "area_id": "kueche" | null}` (HA-Geräteregister).
  Future<void> zigbeeSetArea(String ieee, String? areaId);

  /// TODO Integration: `haven/zigbee/identify` `{"ieee": "0x.."}`
  /// (Z2M `identify` auf `/set`).
  Future<void> zigbeeIdentify(String ieee);

  /// Neu einrichten. TODO Integration: `haven/zigbee/interview`
  /// `{"ieee": "0x.."}` (`bridge/request/device/interview`).
  Future<void> zigbeeInterview(String ieee);

  /// TODO Integration: `haven/zigbee/remove` `{"ieee": "0x..", "force": false}`
  /// (`bridge/request/device/remove`).
  Future<void> zigbeeRemove(String ieee, {bool force = false});

  /// Öffnet das Netz für neue Geräte. TODO Integration:
  /// `haven/zigbee/permit_join` `{"time": 240, "device": "<ieee>|null"}`
  /// (`bridge/request/permit_join`).
  Future<void> zigbeePermitJoin({int seconds = 240, String? viaIeee});

  /// Schließt das Netz wieder (`permit_join` mit `time: 0`).
  Future<void> zigbeeStopJoin();

  /// Netzkarte mit LQI je Verbindung. `haven/zigbee/networkmap`
  /// `{"refresh": bool}` → zwischengespeichertes Ergebnis von
  /// `bridge/request/networkmap` (type raw, routes false) und Zeitstempel.
  /// Mit [refresh] misst Z2M neu (belastet das Netz, bis zu eine Minute).
  Future<ZbNetworkMap> zigbeeNetworkMap({bool refresh = false});
}
