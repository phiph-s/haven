import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import 'widgets/zb_common.dart';
import 'zigbee_model.dart';
import 'zigbee_providers.dart';

/// Wählt einen Raum und setzt ihn. Gibt `true` zurück, wenn sich etwas
/// geändert hat.
Future<bool> pickRoom(
  BuildContext context,
  WidgetRef ref,
  ZbDeviceView view,
) async {
  final rooms = ref.read(snapshotProvider).rooms;
  const none = '__none__';
  final choice = await showZbSheet<String>(
    context,
    builder: (ctx) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'In welchen Raum gehört es?',
          style: HavenText.headline.copyWith(color: ctx.hv.tx),
        ),
        const SizedBox(height: 4),
        Text(view.name, style: HavenText.body.copyWith(color: ctx.hv.tx2)),
        const SizedBox(height: 14),
        for (final r in rooms)
          ZbChoiceRow(
            label: r.name,
            selected: r.id == view.roomId,
            onTap: () => Navigator.of(ctx).pop(r.id),
          ),
        ZbChoiceRow(
          label: 'Kein Raum',
          selected: view.roomId == null,
          onTap: () => Navigator.of(ctx).pop(none),
        ),
      ],
    ),
  );
  if (choice == null) return false;
  final id = choice == none ? null : choice;
  if (id == view.roomId) return false;
  final err = await ref.read(zigbeeProvider.notifier).setArea(view.ieee, id);
  if (!context.mounted) return false;
  if (err != null) {
    zbToast(context, err, error: true);
    return false;
  }
  final name = id == null
      ? null
      : rooms.where((r) => r.id == id).map((r) => r.name).firstOrNull;
  zbToast(
    context,
    name == null
        ? '${view.name} hat keinen Raum'
        : '${view.name} ist jetzt in $name',
  );
  return true;
}

/// Umbenennen: Z2M-Name und HA-Name in einem Schritt.
Future<void> renameDevice(
  BuildContext context,
  WidgetRef ref,
  ZbDeviceView view,
) async {
  final name = await showZbSheet<String>(
    context,
    builder: (ctx) => _RenameForm(initial: view.name),
  );
  if (name == null || name.trim().isEmpty || name.trim() == view.name) return;
  final err = await ref
      .read(zigbeeProvider.notifier)
      .rename(view.ieee, name.trim());
  if (!context.mounted) return;
  zbToast(context, err ?? 'Umbenannt in ${name.trim()}', error: err != null);
}

class _RenameForm extends StatefulWidget {
  const _RenameForm({required this.initial});
  final String initial;

  @override
  State<_RenameForm> createState() => _RenameFormState();
}

class _RenameFormState extends State<_RenameForm> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Umbenennen', style: HavenText.headline.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        Text(
          'Der neue Name gilt in Zigbee2MQTT und in Home Assistant.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 14),
        NameField(controller: _c, autofocus: true, onSubmitted: _done),
        const SizedBox(height: 14),
        HavenButton(
          label: 'Speichern',
          primary: true,
          onTap: () => _done(_c.text),
        ),
      ],
    );
  }

  void _done(String v) => Navigator.of(context).pop(v);
}

/// Textfeld im Stil der App.
class NameField extends StatelessWidget {
  const NameField({
    super.key,
    required this.controller,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    this.hint,
  });
  final TextEditingController controller;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return TextField(
      controller: controller,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      textInputAction: TextInputAction.done,
      cursorColor: hv.acc,
      style: HavenText.label.copyWith(color: hv.tx, fontSize: 16),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: HavenText.label.copyWith(color: hv.tx3, fontSize: 16),
        filled: true,
        fillColor: hv.s2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HavenRadii.m),
          borderSide: BorderSide(color: hv.ln2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HavenRadii.m),
          borderSide: BorderSide(color: hv.ln2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HavenRadii.m),
          borderSide: BorderSide(color: hv.acc, width: 2),
        ),
      ),
    );
  }
}

/// Bestätigung mit Titel, Text und Knopf. `true` bei Bestätigung.
Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  required String text,
  required String action,
  bool destructive = false,
}) async {
  final r = await showZbSheet<bool>(
    context,
    builder: (ctx) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: HavenText.headline.copyWith(color: ctx.hv.tx)),
        const SizedBox(height: 6),
        Text(text, style: HavenText.body.copyWith(color: ctx.hv.tx2)),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: HavenButton(
                label: 'Abbrechen',
                onTap: () => Navigator.of(ctx).pop(false),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: HavenButton(
                label: action,
                primary: !destructive,
                destructive: destructive,
                onTap: () => Navigator.of(ctx).pop(true),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Fragt nach und entfernt ein Geister-Gerät mit `force: true` (Z2M wartet
/// nicht auf das Gerät). Gibt `true` zurück, wenn es entfernt wurde.
Future<bool> removeGhost(
  BuildContext context,
  WidgetRef ref,
  ZbDeviceView view,
) async {
  final ok = await confirmSheet(
    context,
    title: '${view.name} entfernen?',
    text:
        'Das Gerät verschwindet aus Zigbee2MQTT, aus allen Gruppen und aus '
        'Home Assistant. Wenn es doch noch existiert, lässt es sich neu '
        'anlernen.',
    action: 'Entfernen',
    destructive: true,
  );
  if (!ok || !context.mounted) return false;
  final err = await ref
      .read(zigbeeProvider.notifier)
      .remove(view.ieee, force: true);
  if (!context.mounted) return false;
  if (err != null) {
    zbToast(context, err, error: true);
    return false;
  }
  zbToast(context, '${view.name} wurde entfernt');
  return true;
}

/// Text zur Quelle von „zuletzt gesehen“ („laut Zigbee2MQTT“, „laut
/// Netzmessung vom 12.11.“), `null` ohne Quelle.
String? lastSeenSourceLabel(ZbDeviceView v) {
  switch (v.lastSeenSource) {
    case 'z2m':
      return 'laut Zigbee2MQTT';
    case 'message':
      return 'letzte Meldung des Geräts';
    case 'networkmap':
      final t = v.networkMeasuredAt?.toLocal();
      if (t == null) return 'laut Netzmessung';
      String two(int x) => x.toString().padLeft(2, '0');
      return 'laut Netzmessung vom ${two(t.day)}.${two(t.month)}.';
  }
  return null;
}
