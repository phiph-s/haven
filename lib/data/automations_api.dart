import 'models/haven_automation.dart';

/// Haven-Automationen (`haven/automations/*`, ab der Integration mit dem
/// Feature `automations`). Teil von `HavenRepository`.
abstract interface class AutomationsApi {
  /// `haven/automations/list`. Ältere Integration: [HavenAutomations.unsupported].
  Future<HavenAutomations> havenAutomations();

  /// `haven/automations/set` (Admin). Ohne `id` legt die Integration eine
  /// neue an. Liefert die gespeicherte Fassung. Fehler als `HavenException`
  /// mit `code` (`device_taken`, `no_lights`, `invalid_format`, `not_found`).
  Future<HavenAutomation> saveHavenAutomation(HavenAutomation automation);

  /// `haven/automations/delete` (Admin).
  Future<void> deleteHavenAutomation(String id);

  /// `haven/automations/test` (Admin): löst eine Geste testweise aus
  /// (`rotate_left`, `rotate_right`, `single`, `double`, `hold`).
  Future<void> testHavenAutomation(String id, String action);

  /// Ereignis `haven_automation_triggered` (Gesten in Echtzeit).
  Stream<AutomationTrigger> get automationTriggers;

  /// `haven_data_updated` mit `kind: automations`, außerdem nach jedem Verbinden.
  Stream<void> get automationsChanged;
}
