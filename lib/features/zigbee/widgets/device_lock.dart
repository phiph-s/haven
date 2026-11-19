import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haven_switch.dart';
import '../../../data/models/snapshot.dart';
import '../zigbee_model.dart';
import 'zb_common.dart';

/// Domains, die ein Gerät schalten (für die Sperre „immer an“).
const Set<String> kLockableDomains = {'switch', 'light', 'fan'};

/// IEEE und schaltbare Entities eines Geräts: das sperrt [DeviceLockRow].
List<String> lockIdsOf(ZbDeviceView view) => [
  view.ieee,
  for (final e in view.entities)
    if (kLockableDomains.contains(e.domain)) e.entityId,
];

/// Ist das Gerät gesperrt (IEEE oder eine seiner Entities)?
bool isDeviceLocked(HavenSnapshot s, ZbDeviceView view) =>
    s.isLocked(view.ieee) || view.entities.any((e) => s.isLocked(e.entityId));

/// „Immer an“: sperrt das Gerät für jede Steuerung durch Haven (Schalter in
/// der App, Raum aus, Automationen, Zigbee-Befehle). Für Geräte, die nie
/// ausgehen dürfen: die Steckdose von Home Assistant selbst, Kühlschrank,
/// Router. Beim Sperren schaltet Haven ein ausgeschaltetes Gerät erst ein.
class DeviceLockRow extends ConsumerWidget {
  const DeviceLockRow({super.key, required this.view, this.isOn});
  final ZbDeviceView view;

  /// Gerade an? `false`: beim Sperren erst einschalten.
  final bool? isOn;

  Future<void> _set(BuildContext context, WidgetRef ref, bool lock) async {
    final repo = ref.read(repositoryProvider);
    try {
      if (lock && isOn == false) {
        final e = view.entities
            .where((e) => kLockableDomains.contains(e.domain))
            .firstOrNull;
        if (e != null) {
          await repo.callService(e.domain, 'turn_on', entityId: e.entityId);
        } else {
          await repo.zigbeeSet(view.ieee, {'state': 'ON'});
        }
      }
      await repo.setLocked(lockIdsOf(view), lock);
    } catch (e) {
      if (context.mounted) zbToast(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final locked = ref.watch(
      snapshotProvider.select((s) => isDeviceLocked(s, view)),
    );
    return Container(
      key: const ValueKey('device-lock'),
      decoration: BoxDecoration(
        color: locked ? hv.acc.withValues(alpha: 0.12) : hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: locked
            ? Border.all(color: hv.acc.withValues(alpha: 0.5))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: [
          Icon(
            locked ? Icons.lock_rounded : Icons.lock_open_rounded,
            size: 20,
            color: locked ? hv.acc : hv.tx2,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Immer an',
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                ),
                Text(
                  locked
                      ? 'Gesperrt: Haven schaltet dieses Gerät nicht, auch keine Automation.'
                      : 'Sperrt das Gerät gegen versehentliches Ausschalten.',
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
              ],
            ),
          ),
          HavenSwitch(
            value: locked,
            semanticLabel: 'Immer an',
            onChanged: (v) => _set(context, ref, v),
          ),
        ],
      ),
    );
  }
}
