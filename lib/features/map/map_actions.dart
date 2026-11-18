import '../../data/models/floor_plan.dart';
import '../../data/models/zigbee.dart';
import 'map_layers.dart';

/// Was auf der Karte angetippt wurde, grob nach Gerätetyp. Für Räume gibt es
/// [room].
enum MapTarget {
  lamp,

  /// Steckdose oder Relais.
  plug,
  climateSensor,

  /// Heizkörperthermostat.
  thermostat,
  motionSensor,
  contactSensor,

  /// Drehregler oder Taster.
  control,
  otherDevice,
  room,
}

/// Aktion beim Antippen. Eine Kartenart und ein Zieltyp ergeben genau eine
/// Aktion (`mapTapAction`), die Widgets führen sie nur aus.
enum MapTapAction {
  /// Lampe an oder aus.
  toggleLamp,

  /// Steckdose oder Relais schalten, mit Leistung in der Rückmeldung.
  togglePlug,

  /// Kompaktes Info-Sheet mit Messwert, Verlauf, Batterie.
  openClimateSheet,

  /// Thermostat bedienen: Zieltemperatur, Betriebsart, Zustand.
  openThermostat,
  openMotionSheet,
  openBatterySheet,

  /// Funknetz: Knoten wählen, das Netz-Infopanel zeigt den Weg.
  selectNetworkNode,

  /// Lichtschalter: welchen Raum oder welche Automation er steuert.
  showControlInfo,

  /// Nur der Zustand als kurzer Text (Kontakt, Fernbedienung, Rest).
  showStatus,

  /// Raum-Sheet (Lichtsteuerung).
  openRoomSheet,
  openRoomClimate,
  openRoomMotion,
  openRoomBatteries,

  /// Keine Aktion.
  none,
}

/// Antippen nach Kartenart und Zieltyp.
MapTapAction mapTapAction(MapLayer layer, MapTarget target) {
  final isRoom = target == MapTarget.room;
  switch (layer) {
    case MapLayer.combo:
      return switch (target) {
        MapTarget.lamp => MapTapAction.toggleLamp,
        MapTarget.plug => MapTapAction.togglePlug,
        MapTarget.climateSensor => MapTapAction.openClimateSheet,
        MapTarget.thermostat => MapTapAction.openThermostat,
        MapTarget.motionSensor => MapTapAction.openMotionSheet,
        MapTarget.contactSensor ||
        MapTarget.control ||
        MapTarget.otherDevice => MapTapAction.showStatus,
        MapTarget.room => MapTapAction.openRoomSheet,
      };
    case MapLayer.light:
      return switch (target) {
        MapTarget.lamp => MapTapAction.toggleLamp,
        MapTarget.control => MapTapAction.showControlInfo,
        MapTarget.room => MapTapAction.openRoomSheet,
        _ => MapTapAction.showStatus,
      };
    case MapLayer.temperature:
    case MapLayer.humidity:
      return isRoom
          ? MapTapAction.openRoomClimate
          : target == MapTarget.thermostat
          ? MapTapAction.openThermostat
          : MapTapAction.openClimateSheet;
    case MapLayer.presence:
      return isRoom
          ? MapTapAction.openRoomMotion
          : MapTapAction.openMotionSheet;
    case MapLayer.network:
      return isRoom ? MapTapAction.none : MapTapAction.selectNetworkNode;
    case MapLayer.battery:
      return isRoom
          ? MapTapAction.openRoomBatteries
          : MapTapAction.openBatterySheet;
  }
}

/// Aktion beim langen Drücken (Desktop: Rechtsklick).
enum MapHoldAction {
  /// Volles Gerät-Detail (Zigbee-Gerät).
  openDevice,

  /// Kompaktes Licht-Sheet mit Helligkeit, Weiß/Farbe, Ausnahme.
  openLampSheet,
  none,
}

/// Langes Drücken: überall das volle Gerät-Detail, in der Kartenart Licht
/// bei Lampen das Licht-Sheet. Räume haben keine Aktion.
MapHoldAction mapHoldAction(MapLayer layer, MapTarget target) {
  if (target == MapTarget.room) return MapHoldAction.none;
  if (layer == MapLayer.light && target == MapTarget.lamp) {
    return MapHoldAction.openLampSheet;
  }
  return MapHoldAction.openDevice;
}

/// Rechtsklick (Desktop) auf ein Gerät: immer das volle Gerät-Detail.
MapHoldAction mapSecondaryAction(MapLayer layer, MapTarget target) =>
    target == MapTarget.room ? MapHoldAction.none : MapHoldAction.openDevice;

/// Zieltyp eines platzierten Geräts. Der Zigbee-Typ ([zbType], `ZbType.*`)
/// hat Vorrang, dann eine Climate-Entity ([entityId]), sonst entscheidet die
/// Art der Platzierung.
MapTarget mapTargetOf(FloorKind kind, {String? zbType, String? entityId}) {
  switch (zbType) {
    case ZbType.thermostat:
      return MapTarget.thermostat;
    case ZbType.light:
      return MapTarget.lamp;
    case ZbType.plug || ZbType.switch_ || ZbType.relay:
      return MapTarget.plug;
    case ZbType.climate:
      return MapTarget.climateSensor;
    case ZbType.motion || ZbType.presence:
      return MapTarget.motionSensor;
    case ZbType.contact:
      return MapTarget.contactSensor;
    case ZbType.knob || ZbType.remote:
      return MapTarget.control;
  }
  if (entityId != null && entityId.startsWith('climate.')) {
    return MapTarget.thermostat;
  }
  return switch (kind) {
    FloorKind.light => MapTarget.lamp,
    FloorKind.switchKind => MapTarget.plug,
    FloorKind.temperature => MapTarget.climateSensor,
    FloorKind.presence => MapTarget.motionSensor,
    FloorKind.contact => MapTarget.contactSensor,
    FloorKind.remote => MapTarget.control,
    FloorKind.media || FloorKind.device => MapTarget.otherDevice,
  };
}

/// Zigbee-Gerät zu einer Entity (für das Gerät-Detail), sonst `null`.
ZbDevice? zbDeviceForEntity(List<ZbDevice> devices, String entityId) {
  for (final d in devices) {
    if (d.haEntities.contains(entityId)) return d;
  }
  return null;
}
